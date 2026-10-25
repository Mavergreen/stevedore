#ifndef FP_TREE_H
#define FP_TREE_H

#include <stddef.h>

#define FP_REFUSED 2

struct fp_entry {
	char *path;
	unsigned long mode;
	unsigned long long size;
	char *link_target;
	unsigned long nchild;
};

struct fp_tree {
	char *root;
	struct fp_entry *e;
	size_t n, cap;
};

int fp_tree_scan(const char *root, struct fp_tree *t);
void fp_tree_free(struct fp_tree *t);

#endif
