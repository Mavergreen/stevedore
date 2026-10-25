#ifndef FP_GZ_H
#define FP_GZ_H

#include <stddef.h>

#include "buf.h"

int fp_gzip(const unsigned char *in, size_t n, struct fp_buf *out);
int fp_zlib(const unsigned char *in, size_t n, struct fp_buf *out);
int fp_zlib_check(void);
const char *fp_zlib_pinned(void);

#endif
