#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zlib.h>

#include "buf.h"
#include "cpio.h"
#include "gz.h"
#include "tree.h"

static int
read_all(FILE *f, struct fp_buf *b)
{
	size_t got;

	for (;;) {
		if (fp_buf_reserve(b, 65536) != 0)
			return -1;
		got = fread(b->p + b->len, 1, 65536, f);
		b->len += got;
		if (got < 65536)
			return ferror(f) ? -1 : 0;
	}
}

static int
usage(void)
{
	fputs("usage: stevedore gzip|zlib < input > output\n"
	    "       stevedore payload --root DIR --mtime EPOCH --out FILE\n", stderr);
	return 2;
}

static int
filter(const char *name, int (*fn)(const unsigned char *, size_t, struct fp_buf *))
{
	struct fp_buf in = { 0 }, out = { 0 };
	int rc = 0;

	if (read_all(stdin, &in) != 0) {
		perror("stevedore: reading standard input");
		rc = 1;
	} else if (fn(in.p, in.len, &out) != 0) {
		fprintf(stderr, "stevedore: %s failed\n", name);
		rc = 1;
	} else if (fwrite(out.p, 1, out.len, stdout) != out.len || fflush(stdout) != 0) {
		perror("stevedore: writing standard output");
		rc = 1;
	}
	fp_buf_free(&in);
	fp_buf_free(&out);
	return rc;
}

static int
payload(int argc, char **argv)
{
	const char *root = NULL, *mtime_arg = NULL, *outpath = NULL;
	struct fp_tree t;
	struct fp_buf cpio = { 0 }, gz = { 0 };
	char *end;
	long mtime;
	FILE *f;
	int i, rc;

	for (i = 2; i + 1 < argc; i += 2) {
		if (strcmp(argv[i], "--root") == 0)
			root = argv[i + 1];
		else if (strcmp(argv[i], "--mtime") == 0)
			mtime_arg = argv[i + 1];
		else if (strcmp(argv[i], "--out") == 0)
			outpath = argv[i + 1];
		else
			return usage();
	}
	if (i != argc || root == NULL || mtime_arg == NULL || outpath == NULL)
		return usage();
	errno = 0;
	mtime = strtol(mtime_arg, &end, 10);
	if (*mtime_arg < '0' || *mtime_arg > '9' || *end != '\0' || errno != 0) {
		fprintf(stderr, "stevedore: invalid --mtime: %s\n", mtime_arg);
		return 2;
	}

	rc = fp_tree_scan(root, &t);
	if (rc != 0)
		return rc < 0 ? 1 : rc;
	rc = fp_cpio_odc(&t, mtime, &cpio);
	fp_tree_free(&t);
	if (rc != 0) {
		fp_buf_free(&cpio);
		return rc < 0 ? 1 : rc;
	}
	if (fp_gzip(cpio.p, cpio.len, &gz) != 0) {
		fputs("stevedore: gzip failed\n", stderr);
		rc = 1;
	} else {
		size_t tl = strlen(outpath) + 16;
		char *tmp = malloc(tl);

		if (tmp == NULL) {
			fputs("stevedore: out of memory\n", stderr);
			rc = 1;
		} else {
			snprintf(tmp, tl, "%s.stevedore-tmp", outpath);
			if ((f = fopen(tmp, "wb")) == NULL) {
				perror(tmp);
				rc = 1;
			} else {
				size_t w = fwrite(gz.p, 1, gz.len, f);

				if (fclose(f) != 0 || w != gz.len || rename(tmp, outpath) != 0) {
					perror(outpath);
					rc = 1;
					remove(tmp);
				}
			}
			free(tmp);
		}
	}
	fp_buf_free(&cpio);
	fp_buf_free(&gz);
	return rc;
}

int
main(int argc, char **argv)
{
	if (fp_zlib_check() != 0) {
		fprintf(stderr, "stevedore: linked zlib is %s, not the pinned %s\n",
		    zlibVersion(), fp_zlib_pinned());
		return 1;
	}
	if (argc < 2)
		return usage();
	if (argc == 2 && strcmp(argv[1], "gzip") == 0)
		return filter("gzip", fp_gzip);
	if (argc == 2 && strcmp(argv[1], "zlib") == 0)
		return filter("zlib", fp_zlib);
	if (strcmp(argv[1], "payload") == 0)
		return payload(argc, argv);
	return usage();
}
