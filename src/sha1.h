#ifndef FP_SHA1_H
#define FP_SHA1_H

#include <stddef.h>

#define FP_SHA1_LEN 20

struct fp_sha1 {
	unsigned long h[5];
	unsigned long long n;
	unsigned char block[64];
	size_t used;
};

void fp_sha1_init(struct fp_sha1 *s);
void fp_sha1_update(struct fp_sha1 *s, const void *data, size_t n);
void fp_sha1_final(struct fp_sha1 *s, unsigned char out[FP_SHA1_LEN]);
void fp_sha1(const void *data, size_t n, unsigned char out[FP_SHA1_LEN]);
void fp_sha1_hex(const unsigned char sum[FP_SHA1_LEN], char hex[2 * FP_SHA1_LEN + 1]);

#endif
