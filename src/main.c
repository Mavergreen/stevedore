#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zlib.h>

#include "bom.h"
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
	    "       stevedore payload --root DIR --mtime EPOCH --out FILE\n"
	    "       stevedore bom --root DIR --mtime EPOCH --out FILE\n", stderr);
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
write_atomic(const char *outpath, const struct fp_buf *b)
{
	size_t tl = strlen(outpath) + 16, w;
	char *tmp = malloc(tl);
	FILE *f;
	int rc = 0;

	if (tmp == NULL) {
		fputs("stevedore: out of memory\n", stderr);
		return 1;
	}
	snprintf(tmp, tl, "%s.stevedore-tmp", outpath);
	if ((f = fopen(tmp, "wb")) == NULL) {
		perror(tmp);
		rc = 1;
	} else {
		w = fwrite(b->p, 1, b->len, f);
		if (fclose(f) != 0 || w != b->len || rename(tmp, outpath) != 0) {
			perror(outpath);
			rc = 1;
			remove(tmp);
		}
	}
	free(tmp);
	return rc;
}

static int
tree_args(int argc, char **argv, const char **root, long *mtime, const char **outpath)
{
	const char *mtime_arg = NULL;
	char *end;
	int i;

	*root = *outpath = NULL;
	for (i = 2; i + 1 < argc; i += 2) {
		if (strcmp(argv[i], "--root") == 0)
			*root = argv[i + 1];
		else if (strcmp(argv[i], "--mtime") == 0)
			mtime_arg = argv[i + 1];
		else if (strcmp(argv[i], "--out") == 0)
			*outpath = argv[i + 1];
		else
			return usage();
	}
	if (i != argc || *root == NULL || mtime_arg == NULL || *outpath == NULL)
		return usage();
	errno = 0;
	*mtime = strtol(mtime_arg, &end, 10);
	if (*mtime_arg < '0' || *mtime_arg > '9' || *end != '\0' || errno != 0) {
		fprintf(stderr, "stevedore: invalid --mtime: %s\n", mtime_arg);
		return 2;
	}
	return 0;
}

static int
payload(int argc, char **argv)
{
	const char *root, *outpath;
	struct fp_tree t;
	struct fp_buf cpio = { 0 }, gz = { 0 };
	long mtime;
	int rc;

	if ((rc = tree_args(argc, argv, &root, &mtime, &outpath)) != 0)
		return rc;
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
		rc = write_atomic(outpath, &gz);
	}
	fp_buf_free(&cpio);
	fp_buf_free(&gz);
	return rc;
}

static int
bom(int argc, char **argv)
{
	const char *root, *outpath;
	struct fp_tree t;
	struct fp_buf b = { 0 };
	long mtime;
	int rc;

	if ((rc = tree_args(argc, argv, &root, &mtime, &outpath)) != 0)
		return rc;
	rc = fp_tree_scan(root, &t);
	if (rc != 0)
		return rc < 0 ? 1 : rc;
	rc = fp_bom(&t, mtime, &b);
	fp_tree_free(&t);
	if (rc == 0)
		rc = write_atomic(outpath, &b);
	fp_buf_free(&b);
	return rc < 0 ? 1 : rc;
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
	if (strcmp(argv[1], "bom") == 0)
		return bom(argc, argv);
	return usage();
}
