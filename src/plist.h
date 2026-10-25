#ifndef FP_PLIST_H
#define FP_PLIST_H

#include <stddef.h>

#include "buf.h"

#define FP_PLIST_MISSING 1
#define FP_PLIST_MALFORMED 2
#define FP_PLIST_NOT_SCALAR 3

#define FP_PLIST_IS_STRING 1
#define FP_PLIST_IS_INTEGER 2
#define FP_PLIST_IS_OTHER 3

struct fp_plist;

int fp_plist_read(const char *path, struct fp_plist **out);
int fp_plist_parse(const unsigned char *data, size_t n, const char *name, struct fp_plist **out);
const char *fp_plist_get(const struct fp_plist *p, const char *keypath);
int fp_plist_kind(const struct fp_plist *p, const char *keypath);
const char *fp_plist_lookup(const struct fp_plist *p, const char *keypath, size_t *len, int *why);
int fp_plist_set(struct fp_plist *p, const char *keypath, const char *type, const char *value);
int fp_plist_write_xml(const struct fp_plist *p, struct fp_buf *out);
void fp_plist_free(struct fp_plist *p);

#endif
