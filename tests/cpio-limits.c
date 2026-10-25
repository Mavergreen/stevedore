#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cpio.h"

static struct fp_entry
entry(char *path, unsigned long mode, unsigned long long size)
{
	struct fp_entry e;

	memset(&e, 0, sizeof e);
	e.path = path;
	e.mode = mode;
	e.size = size;
	return e;
}

int
main(int argc, char **argv)
{
	struct fp_entry es[3];
	struct fp_tree t;
	struct fp_buf out = { 0 };
	long mtime = 1700000000;
	char *longname;
	int rc;

	if (argc != 2) {
		fputs("usage: stevedore-cpio-limits size|size-max|name|name-max|payload|mtime\n", stderr);
		return 64;
	}
	memset(&t, 0, sizeof t);
	t.root = "/nonexistent";
	t.e = es;
	t.n = 2;
	es[0] = entry(".", 040755, 0);
	es[1] = entry("./big", 0100644, 0100000000000ULL);

	if (strcmp(argv[1], "size-max") == 0) {
		es[1].size = 077777777777ULL;
	} else if (strcmp(argv[1], "name") == 0 || strcmp(argv[1], "name-max") == 0) {
		size_t len = strcmp(argv[1], "name") == 0 ? 262143 : 262142;

		longname = malloc(len + 1);
		memset(longname, 'x', len);
		longname[len] = '\0';
		memcpy(longname, "./", 2);
		es[1] = entry(longname, 0100644, 0);
	} else if (strcmp(argv[1], "payload") == 0) {
		es[1] = entry("./a", 0100644, 030000000000ULL);
		es[2] = entry("./b", 0100644, 030000000000ULL);
		t.n = 3;
	} else if (strcmp(argv[1], "mtime") == 0) {
		mtime = -1;
		es[1] = entry("./f", 0100644, 0);
	} else if (strcmp(argv[1], "size") != 0) {
		return 64;
	}
	rc = fp_cpio_odc(&t, mtime, &out, NULL);
	printf("rc=%d len=%lu\n", rc, (unsigned long)out.len);
	return rc;
}
