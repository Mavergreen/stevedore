#ifndef FP_XAR_H
#define FP_XAR_H

#include <stddef.h>
#include <stdio.h>

#include "buf.h"
#include "sha1.h"

#define FP_ENC_NONE 0
#define FP_ENC_ZLIB 1

#define FP_XAR_FILE 0
#define FP_XAR_DIR 1
#define FP_XAR_SYMLINK 2
#define FP_XAR_OTHER 3

struct fp_xar_entry {
	const char *path;
	const unsigned char *data;
	size_t len;
	int enc;
};

struct fp_xar_file {
	char *path;
	int type, unsafe, has_data, enc;
	unsigned long mode;
	unsigned long long offset, length, size;
	unsigned char archived[FP_SHA1_LEN], extracted[FP_SHA1_LEN];
};

struct fp_xar {
	FILE *f;
	unsigned long long heap, heap_len;
	struct fp_buf toc;
	struct fp_xar_file *file;
	size_t n, cap;
};

typedef int (*fp_xar_sink)(void *ctx, const unsigned char *p, size_t n);

int fp_xar_write(const struct fp_xar_entry *e, size_t n, long mtime, struct fp_buf *out);
int fp_xar_write_product(const struct fp_xar_entry *e, size_t n, long mtime, struct fp_buf *out);
int fp_xar_read(const char *path, struct fp_xar *x);
int fp_xar_check_safe(const struct fp_xar *x);
int fp_xar_extract(struct fp_xar *x, size_t i, fp_xar_sink sink, void *ctx);
void fp_xar_free(struct fp_xar *x);

#endif
