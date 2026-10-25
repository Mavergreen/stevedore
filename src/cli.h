#ifndef FP_CLI_H
#define FP_CLI_H

#include <stdio.h>

#include "buf.h"

int fp_read_all(FILE *f, struct fp_buf *b);
int fp_write_atomic(const char *outpath, const struct fp_buf *b, long mode);
int fp_parse_mtime(const char *arg, long *mtime);

#endif
