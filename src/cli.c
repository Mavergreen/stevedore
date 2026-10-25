#define _POSIX_C_SOURCE 200809L

#include "cli.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

int
fp_read_all(FILE *f, struct fp_buf *b)
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

int
fp_write_atomic(const char *outpath, const struct fp_buf *b, long mode)
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

int
fp_parse_mtime(const char *arg, long *mtime)
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
