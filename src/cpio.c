#define _POSIX_C_SOURCE 200809L

#include "cpio.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define HDR 76
#define TRAILER "TRAILER!!!"
#define BLOCK 512ULL
#define PAYLOAD_MAX 0xFFFFFFFFULL

static int
refuse(const char *reason, const char *path)
{
	fprintf(stderr, "stevedore: %s: %s\n", reason, path);
	return FP_REFUSED;
}

static int
fits(unsigned long long v, int width)
{
	return (v >> (3 * width)) == 0;
}

static void
oct(unsigned char *dst, int width, unsigned long long v)
{
	while (width-- > 0) {
		dst[width] = (unsigned char)('0' + (v & 7));
		v >>= 3;
	}
}

static int
header(struct fp_buf *out, unsigned long long ino, unsigned long long mode, unsigned long long nlink,
    unsigned long long mtime, const char *name, unsigned long long filesize)
{
	unsigned char h[HDR];
	size_t namesize = strlen(name) + 1;

	memcpy(h, "070707", 6);
	oct(h + 6, 6, 0);
	oct(h + 12, 6, ino);
	oct(h + 18, 6, mode);
	oct(h + 24, 6, 0);
	oct(h + 30, 6, 0);
	oct(h + 36, 6, nlink);
	oct(h + 42, 6, 0);
	oct(h + 48, 11, mtime);
	oct(h + 59, 6, namesize);
	oct(h + 65, 11, filesize);
	return fp_buf_append(out, h, HDR) || fp_buf_append(out, name, namesize);
}

static unsigned long long
nlink_of(const struct fp_entry *e)
{
	return (e->mode & 0170000) == 040000 ? 2 + (unsigned long long)e->nchild : 1;
}

static int
validate(const struct fp_tree *t, long mtime, unsigned long long *total)
{
	unsigned long long sum = 0;
	size_t i;
	char num[32];

	if (mtime < 0 || !fits((unsigned long long)mtime, 11)) {
		snprintf(num, sizeof num, "%ld", mtime);
		return refuse("mtime out of range", num);
	}
	if (!fits(t->n + 1, 6))
		return refuse("too many entries", ".");
	for (i = 0; i < t->n; i++) {
		const struct fp_entry *e = &t->e[i];
		unsigned long long size = (e->mode & 0170000) == 040000 ? 0 : e->size;

		if (!fits(strlen(e->path) + 1, 6))
			return refuse("path too long", e->path);
		if (!fits(e->mode, 6))
			return refuse("mode out of range", e->path);
		if (!fits(nlink_of(e), 6))
			return refuse("too many entries", e->path);
		if (!fits(size, 11))
			return refuse("file too large", e->path);
		sum += HDR + strlen(e->path) + 1 + size;
		if (sum > PAYLOAD_MAX)
			return refuse("payload too large", e->path);
	}
	sum += HDR + sizeof TRAILER;
	sum = (sum + BLOCK - 1) / BLOCK * BLOCK;
	if (sum > PAYLOAD_MAX)
		return refuse("payload too large", ".");
	*total = sum;
	return 0;
}

static int
read_file(const struct fp_tree *t, const struct fp_entry *e, struct fp_buf *out)
{
	size_t rootlen = strlen(t->root);
	char *fs = malloc(rootlen + strlen(e->path) + 1);
	FILE *f;
	int rc = -1;

	if (fs == NULL) {
		fputs("stevedore: out of memory\n", stderr);
		return -1;
	}
	memcpy(fs, t->root, rootlen);
	strcpy(fs + rootlen, e->path + 1);
	f = fopen(fs, "rb");
	if (f == NULL) {
		fprintf(stderr, "stevedore: cannot open: %s: %s\n", e->path, strerror(errno));
	} else if (fread(out->p + out->len, 1, (size_t)e->size, f) != (size_t)e->size || fgetc(f) != EOF) {
		fprintf(stderr, "stevedore: file changed while reading: %s\n", e->path);
	} else {
		out->len += (size_t)e->size;
		rc = 0;
	}
	if (f != NULL)
		fclose(f);
	free(fs);
	return rc;
}

int
fp_cpio_odc(const struct fp_tree *t, long mtime, struct fp_buf *out, size_t *data_at)
{
	size_t start = out->len, i, j, *order;
	unsigned long long total;
	int rc = validate(t, mtime, &total);

	if (rc != 0)
		return rc;
	if (total > (size_t)-1 || fp_buf_reserve(out, (size_t)total) != 0 || (order = fp_tree_dfs(t)) == NULL) {
		fputs("stevedore: out of memory\n", stderr);
		return -1;
	}
	for (j = 0; j < t->n; j++) {
		const struct fp_entry *e = &t->e[i = order[j]];
		unsigned long long type = e->mode & 0170000;

		if (header(out, j + 1, e->mode, nlink_of(e), (unsigned long long)mtime, e->path,
		    type == 040000 ? 0 : e->size) != 0)
			goto oom;
		if (data_at != NULL)
			data_at[i] = out->len;
		if (type == 0120000) {
			if (fp_buf_append(out, e->link_target, (size_t)e->size) != 0)
				goto oom;
		} else if (type == 0100000 && e->size > 0 && read_file(t, e, out) != 0) {
			rc = -1;
			goto fail;
		}
	}
	if (header(out, t->n + 1, 0, 1, 0, TRAILER, 0) != 0)
		goto oom;
	if (fp_buf_reserve(out, (size_t)(BLOCK - 1)) != 0)
		goto oom;
	while ((out->len - start) % BLOCK != 0)
		out->p[out->len++] = 0;
	free(order);
	return 0;
oom:
	fputs("stevedore: out of memory\n", stderr);
	rc = -1;
fail:
	free(order);
	out->len = start;
	return rc;
}

static int
unoct(const unsigned char *p, int width, unsigned long long *v)
{
	*v = 0;
	while (width-- > 0) {
		if (*p < '0' || *p > '7')
			return -1;
		*v = *v << 3 | (unsigned long long)(*p++ - '0');
	}
	return 0;
}

static int
safe_relative(const char *s)
{
	const char *c = s, *e;

	if (*s == '\0' || *s == '/')
		return 0;
	for (;;) {
		e = strchr(c, '/');
		if (e == c || (e ? e - c : (long)strlen(c)) == 0)
			return 0;
		if ((c[0] == '.' && (c[1] == '/' || c[1] == '\0'))
		    || (c[0] == '.' && c[1] == '.' && (c[2] == '/' || c[2] == '\0')))
			return 0;
		if (e == NULL)
			return 1;
		c = e + 1;
	}
}

static int
write_all(int fd, const unsigned char *p, size_t n)
{
	ssize_t w;

	while (n > 0) {
		if ((w = write(fd, p, n)) < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		p += w;
		n -= (size_t)w;
	}
	return 0;
}

int
fp_cpio_odc_extract(const unsigned char *p, size_t n, const char *dir)
{
	unsigned long long mode, namesize, filesize;
	size_t at = 0, dl = strlen(dir), cap = 0, nm = 0, i;
	struct { char *path; mode_t mode; } *made = NULL, *grown;
	const char *name;
	char *path = NULL;
	int rc = 0, fd;

	while (rc == 0) {
		if (n - at < HDR || memcmp(p + at, "070707", 6) != 0 || unoct(p + at + 18, 6, &mode) != 0
		    || unoct(p + at + 59, 6, &namesize) != 0 || unoct(p + at + 65, 11, &filesize) != 0
		    || namesize == 0 || namesize > n - at - HDR || filesize > n - at - HDR - namesize
		    || p[at + HDR + namesize - 1] != '\0') {
			rc = refuse("malformed cpio archive", dir);
			break;
		}
		name = (const char *)p + at + HDR;
		at += HDR + (size_t)namesize;
		if (strcmp(name, TRAILER) == 0)
			break;
		if (name[0] == '.' && name[1] == '/')
			name += 2;
		else if (strcmp(name, ".") == 0)
			name = "";
		if (*name != '\0' && !safe_relative(name)) {
			rc = refuse("unsafe name in cpio archive", name);
			break;
		}
		free(path);
		if ((path = malloc(dl + strlen(name) + 2)) == NULL) {
			fputs("stevedore: out of memory\n", stderr);
			rc = -1;
			break;
		}
		snprintf(path, dl + strlen(name) + 2, *name ? "%s/%s" : "%s", dir, name);
		if ((mode & 0170000) == 040000) {
			if (*name != '\0' && mkdir(path, 0700) != 0) {
				fprintf(stderr, "stevedore: %s: %s\n", path, strerror(errno));
				rc = -1;
			}
		} else if ((mode & 0170000) == 0100000 && *name != '\0') {
			if ((fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600)) < 0
			    || write_all(fd, p + at, (size_t)filesize) != 0) {
				fprintf(stderr, "stevedore: %s: %s\n", path, strerror(errno));
				rc = -1;
			}
			if (fd >= 0 && close(fd) != 0 && rc == 0) {
				fprintf(stderr, "stevedore: %s: %s\n", path, strerror(errno));
				rc = -1;
			}
		} else if ((mode & 0170000) == 0120000) {
			rc = refuse("symlink in cpio archive", name);
		} else {
			rc = refuse("unsupported file type in cpio archive", *name ? name : ".");
		}
		at += (size_t)filesize;
		if (rc != 0)
			break;
		if (nm == cap) {
			cap = cap ? cap * 2 : 16;
			if ((grown = realloc(made, cap * sizeof *made)) == NULL) {
				fputs("stevedore: out of memory\n", stderr);
				rc = -1;
				break;
			}
			made = grown;
		}
		made[nm].path = path;
		made[nm++].mode = (mode_t)(mode & 01777);
		path = NULL;
	}
	free(path);
	for (i = nm; rc == 0 && i-- > 0;)
		if (chmod(made[i].path, made[i].mode) != 0) {
			fprintf(stderr, "stevedore: %s: %s\n", made[i].path, strerror(errno));
			rc = -1;
		}
	for (i = 0; i < nm; i++)
		free(made[i].path);
	free(made);
	return rc;
}
