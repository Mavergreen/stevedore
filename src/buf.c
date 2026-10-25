#include "buf.h"

#include <stdlib.h>
#include <string.h>

int
fp_buf_reserve(struct fp_buf *b, size_t more)
{
	size_t want, cap;
	unsigned char *p;

	if (more > (size_t)-1 - b->len)
		return -1;
	want = b->len + more;
	if (want <= b->cap)
		return 0;
	cap = b->cap ? b->cap : 64;
	while (cap < want)
		cap = cap > (size_t)-1 / 2 ? want : cap * 2;
	p = realloc(b->p, cap);
	if (p == NULL)
		return -1;
	b->p = p;
	b->cap = cap;
	return 0;
}

int
fp_buf_append(struct fp_buf *b, const void *data, size_t n)
{
	if (n == 0)
		return 0;
	if (fp_buf_reserve(b, n) != 0)
		return -1;
	memcpy(b->p + b->len, data, n);
	b->len += n;
	return 0;
}

void
fp_buf_free(struct fp_buf *b)
{
	free(b->p);
	b->p = NULL;
	b->len = b->cap = 0;
}
