#include <stdio.h>
#include <string.h>

#include <zlib.h>

#include "buf.h"
#include "gz.h"

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
	fputs("usage: stevedore gzip|zlib < input > output\n", stderr);
	return 2;
}

int
main(int argc, char **argv)
{
	struct fp_buf in = { 0 }, out = { 0 };
	int (*fn)(const unsigned char *, size_t, struct fp_buf *);
	int rc = 0;

	if (fp_zlib_check() != 0) {
		fprintf(stderr, "stevedore: linked zlib is %s, not the pinned %s\n",
		    zlibVersion(), fp_zlib_pinned());
		return 1;
	}
	if (argc != 2)
		return usage();
	if (strcmp(argv[1], "gzip") == 0)
		fn = fp_gzip;
	else if (strcmp(argv[1], "zlib") == 0)
		fn = fp_zlib;
	else
		return usage();

	if (read_all(stdin, &in) != 0) {
		perror("stevedore: reading standard input");
		rc = 1;
	} else if (fn(in.p, in.len, &out) != 0) {
		fprintf(stderr, "stevedore: %s failed\n", argv[1]);
		rc = 1;
	} else if (fwrite(out.p, 1, out.len, stdout) != out.len || fflush(stdout) != 0) {
		perror("stevedore: writing standard output");
		rc = 1;
	}
	fp_buf_free(&in);
	fp_buf_free(&out);
	return rc;
}
