#include <limits.h>

#include "component.c"

int
main(void)
{
	struct fp_buf o = { 0 };

	if (payload_element(&o, ULLONG_MAX, ULLONG_MAX) != 0 || fwrite(o.p, 1, o.len, stdout) != o.len)
		return 1;
	fp_buf_free(&o);
	return fflush(stdout) != 0;
}
