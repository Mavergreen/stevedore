#ifndef FP_BUF_H
#define FP_BUF_H

#include <stddef.h>

struct fp_buf {
	unsigned char *p;
	size_t len, cap;
};

int fp_buf_reserve(struct fp_buf *b, size_t more);
int fp_buf_append(struct fp_buf *b, const void *data, size_t n);
void fp_buf_free(struct fp_buf *b);

#endif
