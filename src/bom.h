#ifndef FP_BOM_H
#define FP_BOM_H

#include "buf.h"
#include "tree.h"

int fp_bom(const struct fp_tree *t, long mtime, struct fp_buf *out);

#endif
