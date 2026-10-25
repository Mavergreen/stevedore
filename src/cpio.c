#include "cpio.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
fp_cpio_odc(const struct fp_tree *t, long mtime, struct fp_buf *out)
{
	size_t start = out->len, i;
	unsigned long long total;
	int rc = validate(t, mtime, &total);

	if (rc != 0)
		return rc;
	if (total > (size_t)-1 || fp_buf_reserve(out, (size_t)total) != 0) {
		fputs("stevedore: out of memory\n", stderr);
		return -1;
	}
	for (i = 0; i < t->n; i++) {
		const struct fp_entry *e = &t->e[i];
		unsigned long long type = e->mode & 0170000;

		if (header(out, i + 1, e->mode, nlink_of(e), (unsigned long long)mtime, e->path,
		    type == 040000 ? 0 : e->size) != 0)
			goto oom;
		if (type == 0120000) {
			if (fp_buf_append(out, e->link_target, (size_t)e->size) != 0)
				goto oom;
		} else if (type == 0100000 && e->size > 0 && read_file(t, e, out) != 0) {
			out->len = start;
			return -1;
		}
	}
	if (header(out, t->n + 1, 0, 1, 0, TRAILER, 0) != 0)
		goto oom;
	if (fp_buf_reserve(out, (size_t)(BLOCK - 1)) != 0)
		goto oom;
	while ((out->len - start) % BLOCK != 0)
		out->p[out->len++] = 0;
	return 0;
oom:
	fputs("stevedore: out of memory\n", stderr);
	out->len = start;
	return -1;
}
