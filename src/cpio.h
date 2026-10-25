#ifndef FP_CPIO_H
#define FP_CPIO_H

#include "buf.h"
#include "tree.h"

int fp_cpio_odc(const struct fp_tree *t, long mtime, struct fp_buf *out);

#endif
