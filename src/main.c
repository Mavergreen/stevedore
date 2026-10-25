#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#include <zlib.h>

#include "bom.h"
#include "buf.h"
#include "cpio.h"
#include "gz.h"
#include "plist.h"
#include "tree.h"
#include "xar.h"

#define FP_SCRIPTS_MAX (64 << 20)

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
	    "       stevedore bom --root DIR --mtime EPOCH --out FILE\n"
	    "       stevedore plist get FILE KEYPATH         (scalars only: a dict or array exits 3)\n"
	    "       stevedore plist has FILE KEYPATH\n"
	    "       stevedore plist set FILE KEYPATH string|integer|real|bool VALUE\n"
	    "           (adds a missing entry; an existing one keeps its type, and a dict or array is refused)\n"
	    "       stevedore plist xml1 FILE\n"
	    "       stevedore sha1 < input\n"
	    "       stevedore xar --mtime EPOCH --out FILE {zlib|none NAME SOURCE}...\n"
	    "       stevedore expand PKG DIR\n"
	    "       stevedore toc PKG\n", stderr);
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
write_atomic(const char *outpath, const struct fp_buf *b, long mode)
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
		if (fclose(f) != 0 || w != b->len || (mode >= 0 && chmod(tmp, (mode_t)mode) != 0)
		    || rename(tmp, outpath) != 0) {
			perror(outpath);
			rc = 1;
			remove(tmp);
		}
	}
	free(tmp);
	return rc;
}

static int
parse_mtime(const char *arg, long *mtime)
{
	char *end;

	errno = 0;
	*mtime = strtol(arg, &end, 10);
	if (*arg < '0' || *arg > '9' || *end != '\0' || errno != 0) {
		fprintf(stderr, "stevedore: invalid --mtime: %s\n", arg);
		return 2;
	}
	return 0;
}

static int
tree_args(int argc, char **argv, const char **root, long *mtime, const char **outpath)
{
	const char *mtime_arg = NULL;
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
	return parse_mtime(mtime_arg, mtime);
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
		rc = write_atomic(outpath, &gz, -1);
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
		rc = write_atomic(outpath, &b, -1);
	fp_buf_free(&b);
	return rc < 0 ? 1 : rc;
}

static int
plist(int argc, char **argv)
{
	struct fp_plist *p;
	struct fp_buf b = { 0 };
	const char *v;
	size_t len = 0;
	struct stat st;
	long mode = -1;
	int rc, why;

	if (!((argc == 4 && strcmp(argv[2], "xml1") == 0) || (argc == 5 && strcmp(argv[2], "get") == 0)
	    || (argc == 5 && strcmp(argv[2], "has") == 0) || (argc == 7 && strcmp(argv[2], "set") == 0)))
		return usage();
	if (argv[2][0] == 's' && lstat(argv[3], &st) == 0) {
		if (!S_ISREG(st.st_mode)) {
			fprintf(stderr, "stevedore: %s: not a regular file; set edits only a regular file, never through a symlink\n", argv[3]);
			return FP_PLIST_MALFORMED;
		}
		mode = (long)(st.st_mode & 07777);
	}
	if ((rc = fp_plist_read(argv[3], &p)) != 0)
		return rc;
	if (argv[2][0] == 'h') {
		v = fp_plist_lookup(p, argv[4], &len, &why);
		rc = v != NULL || why == FP_PLIST_NOT_SCALAR ? 0 : why == FP_PLIST_MISSING ? 1 : 2;
		if (rc == 2)
			fputs("stevedore: out of memory\n", stderr);
	} else if (argv[2][0] == 'g') {
		if ((v = fp_plist_lookup(p, argv[4], &len, &why)) == NULL) {
			if (why == FP_PLIST_NOT_SCALAR)
				fprintf(stderr, "stevedore: %s: %s is a dict or array; get prints scalars only\n", argv[3], argv[4]);
			else
				fprintf(stderr, "stevedore: %s: %s: %s\n", argv[3], argv[4], why == FP_PLIST_MISSING ? "no such entry" : "out of memory");
			rc = why ? why : FP_PLIST_MALFORMED;
		} else if (fwrite(v, 1, len, stdout) != len || putchar('\n') == EOF || fflush(stdout) != 0) {
			perror("stevedore: writing standard output");
			rc = 2;
		}
	} else if (argv[2][0] == 's') {
		rc = fp_plist_set(p, argv[4], argv[5], argv[6]);
		if (rc == 0 && fp_plist_write_xml(p, &b) != 0) {
			fputs("stevedore: out of memory\n", stderr);
			rc = 2;
		} else if (rc == 0) {
			rc = write_atomic(argv[3], &b, mode) != 0 ? 2 : 0;
		}
	} else if (fp_plist_write_xml(p, &b) != 0) {
		fputs("stevedore: out of memory\n", stderr);
		rc = 2;
	} else if (fwrite(b.p, 1, b.len, stdout) != b.len || fflush(stdout) != 0) {
		perror("stevedore: writing standard output");
		rc = 2;
	}
	fp_buf_free(&b);
	fp_plist_free(p);
	return rc;
}

static int
sha1(void)
{
	struct fp_buf in = { 0 };
	unsigned char sum[FP_SHA1_LEN];
	char hex[2 * FP_SHA1_LEN + 1];
	int rc = 0;

	if (read_all(stdin, &in) != 0) {
		perror("stevedore: reading standard input");
		rc = 1;
	} else {
		fp_sha1(in.p, in.len, sum);
		fp_sha1_hex(sum, hex);
		if (printf("%s\n", hex) < 0 || fflush(stdout) != 0) {
			perror("stevedore: writing standard output");
			rc = 1;
		}
	}
	fp_buf_free(&in);
	return rc;
}

static int
xar(int argc, char **argv)
{
	const char *mtime_arg = NULL, *outpath = NULL;
	struct fp_xar_entry *e;
	struct fp_buf *data, out = { 0 };
	size_t n = 0, j;
	long mtime;
	FILE *f;
	int i, rc;

	for (i = 2; i + 1 < argc && strncmp(argv[i], "--", 2) == 0; i += 2) {
		if (strcmp(argv[i], "--mtime") == 0)
			mtime_arg = argv[i + 1];
		else if (strcmp(argv[i], "--out") == 0)
			outpath = argv[i + 1];
		else
			return usage();
	}
	if (mtime_arg == NULL || outpath == NULL || i == argc || (argc - i) % 3 != 0)
		return usage();
	if ((rc = parse_mtime(mtime_arg, &mtime)) != 0)
		return rc;
	e = calloc((size_t)(argc - i) / 3, sizeof *e);
	data = calloc((size_t)(argc - i) / 3, sizeof *data);
	if (e == NULL || data == NULL) {
		fputs("stevedore: out of memory\n", stderr);
		rc = 1;
	}
	for (; rc == 0 && i < argc; i += 3, n++) {
		f = NULL;
		if (strcmp(argv[i], "zlib") == 0)
			e[n].enc = FP_ENC_ZLIB;
		else if (strcmp(argv[i], "none") == 0)
			e[n].enc = FP_ENC_NONE;
		else
			rc = usage();
		e[n].path = argv[i + 1];
		if (rc == 0 && ((f = fopen(argv[i + 2], "rb")) == NULL || read_all(f, &data[n]) != 0)) {
			perror(argv[i + 2]);
			rc = 2;
		}
		if (f != NULL)
			fclose(f);
		e[n].data = data[n].p;
		e[n].len = data[n].len;
	}
	if (rc == 0 && (rc = fp_xar_write(e, n, mtime, &out)) == 0)
		rc = write_atomic(outpath, &out, -1);
	for (j = 0; j < n; j++)
		fp_buf_free(&data[j]);
	free(e);
	free(data);
	fp_buf_free(&out);
	return rc < 0 ? 1 : rc;
}

static char *
under(const char *dir, const char *path)
{
	size_t l = strlen(dir) + strlen(path) + 2;
	char *s = malloc(l);

	if (s != NULL)
		snprintf(s, l, "%s/%s", dir, path);
	return s;
}

struct file_sink {
	FILE *f;
	const char *path;
};

static int
file_sink(void *ctx, const unsigned char *p, size_t n)
{
	struct file_sink *s = ctx;

	if (fwrite(p, 1, n, s->f) == n)
		return 0;
	perror(s->path);
	return 1;
}

static int
buf_sink(void *ctx, const unsigned char *p, size_t n)
{
	if (fp_buf_append(ctx, p, n) == 0)
		return 0;
	fputs("stevedore: out of memory\n", stderr);
	return 1;
}

static int
is_scripts(const char *path)
{
	const char *slash = strchr(path, '/');

	if (strcmp(path, "Scripts") == 0)
		return 1;
	return slash != NULL && strcmp(slash, "/Scripts") == 0 && slash - path > 4
	    && memcmp(slash - 4, ".pkg", 4) == 0;
}

static int
expand_scripts(struct fp_xar *x, size_t i, const char *p)
{
	struct fp_buf gz = { 0 }, cpio = { 0 };
	int rc;

	if (x->file[i].size > FP_SCRIPTS_MAX) {
		fprintf(stderr, "stevedore: expands past %d MiB: %s\n", FP_SCRIPTS_MAX >> 20, x->file[i].path);
		return 2;
	}
	rc = fp_xar_extract(x, i, buf_sink, &gz);
	if (rc == 0 && (rc = fp_gunzip(gz.p, gz.len, FP_SCRIPTS_MAX, &cpio)) != 0) {
		if (rc == -2)
			fprintf(stderr, "stevedore: not a gzipped cpio archive: %s\n", x->file[i].path);
		else if (rc == -3)
			fprintf(stderr, "stevedore: expands past %d MiB: %s\n", FP_SCRIPTS_MAX >> 20, x->file[i].path);
		else
			fputs("stevedore: out of memory\n", stderr);
		rc = rc == -1 ? 1 : 2;
	}
	if (rc == 0 && mkdir(p, 0700) != 0) {
		perror(p);
		rc = 1;
	}
	if (rc == 0)
		rc = fp_cpio_odc_extract(cpio.p, cpio.len, p);
	fp_buf_free(&gz);
	fp_buf_free(&cpio);
	return rc;
}

static int
expand_into(struct fp_xar *x, const char *dir)
{
	struct file_sink fs;
	char *p;
	size_t i;
	int rc = 0, fd;

	for (i = 0; rc == 0 && i < x->n; i++) {
		if ((p = under(dir, x->file[i].path)) == NULL) {
			fputs("stevedore: out of memory\n", stderr);
			rc = 1;
		} else if (x->file[i].type == FP_XAR_DIR) {
			if (mkdir(p, 0700) != 0) {
				perror(p);
				rc = 1;
			}
		} else if (is_scripts(x->file[i].path)) {
			rc = expand_scripts(x, i, p);
		} else if ((fd = open(p, O_WRONLY | O_CREAT | O_EXCL, 0600)) < 0 || (fs.f = fdopen(fd, "wb")) == NULL) {
			perror(p);
			if (fd >= 0)
				close(fd);
			rc = 1;
		} else {
			fs.path = p;
			rc = fp_xar_extract(x, i, file_sink, &fs);
			if (fclose(fs.f) != 0 && rc == 0) {
				perror(p);
				rc = 1;
			}
		}
		free(p);
	}
	while (rc == 0 && i-- > 0) {
		if (is_scripts(x->file[i].path))
			continue;
		if ((p = under(dir, x->file[i].path)) == NULL || chmod(p, (mode_t)x->file[i].mode) != 0) {
			perror(p ? p : dir);
			rc = 1;
		}
		free(p);
	}
	return rc;
}

static void
remove_tree(const char *path)
{
	struct stat st;
	struct dirent *de;
	DIR *d;
	char *p;

	if (lstat(path, &st) != 0)
		return;
	if (!S_ISDIR(st.st_mode)) {
		unlink(path);
		return;
	}
	chmod(path, 0700);
	if ((d = opendir(path)) != NULL) {
		while ((de = readdir(d)) != NULL) {
			if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
				continue;
			if ((p = under(path, de->d_name)) != NULL)
				remove_tree(p);
			free(p);
		}
		closedir(d);
	}
	rmdir(path);
}

static int
expand(const char *pkg, const char *dir)
{
	struct fp_xar x;
	struct stat st;
	char *tmp = NULL;
	size_t l = strlen(dir);
	mode_t um;
	int rc;

	while (l > 1 && dir[l - 1] == '/')
		l--;
	if ((rc = fp_xar_read(pkg, &x)) == 0)
		rc = fp_xar_check_safe(&x);
	if (rc == 0 && lstat(dir, &st) == 0) {
		fprintf(stderr, "stevedore: %s: %s\n", dir, strerror(EEXIST));
		rc = 1;
	}
	if (rc == 0 && (tmp = malloc(l + 40)) == NULL) {
		fputs("stevedore: out of memory\n", stderr);
		rc = 1;
	}
	if (rc == 0) {
		snprintf(tmp, l + 40, "%.*s.stevedore-%ld", (int)l, dir, (long)getpid());
		if (mkdir(tmp, 0700) != 0) {
			perror(tmp);
			rc = 1;
		} else {
			rc = expand_into(&x, tmp);
			um = umask(0);
			umask(um);
			if (rc == 0 && (chmod(tmp, 0755 & ~um) != 0 || rename(tmp, dir) != 0)) {
				perror(dir);
				rc = 1;
			}
			if (rc != 0)
				remove_tree(tmp);
		}
	}
	free(tmp);
	fp_xar_free(&x);
	return rc < 0 ? 1 : rc;
}

static int
toc(const char *pkg)
{
	struct fp_xar x;
	int rc;

	if ((rc = fp_xar_read(pkg, &x)) == 0
	    && (fwrite(x.toc.p, 1, x.toc.len, stdout) != x.toc.len || fflush(stdout) != 0)) {
		perror("stevedore: writing standard output");
		rc = 1;
	}
	fp_xar_free(&x);
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
	if (strcmp(argv[1], "plist") == 0)
		return plist(argc, argv);
	if (strcmp(argv[1], "bom") == 0)
		return bom(argc, argv);
	if (argc == 2 && strcmp(argv[1], "sha1") == 0)
		return sha1();
	if (strcmp(argv[1], "xar") == 0)
		return xar(argc, argv);
	if (argc == 4 && strcmp(argv[1], "expand") == 0)
		return expand(argv[2], argv[3]);
	if (argc == 3 && strcmp(argv[1], "toc") == 0)
		return toc(argv[2]);
	return usage();
}
