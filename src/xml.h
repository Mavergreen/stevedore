#ifndef FP_XML_H
#define FP_XML_H

#include <stddef.h>

#include "buf.h"

#define FP_XML_ELEMENT 0
#define FP_XML_TEXT 1
#define FP_XML_COMMENT 2

struct fp_xml_attr {
	char *name, *value;
};

struct fp_xml_node {
	int kind;
	char *name, *text;
	struct fp_xml_attr *attr;
	size_t nattr, capattr;
	struct fp_xml_node **child;
	size_t nchild, capchild;
};

struct fp_xml_doc {
	int has_decl;
	char *encoding, *standalone;
	struct fp_xml_node *root;
};

int fp_xml_parse(const unsigned char *p, size_t n, const char *name, struct fp_xml_doc *d);
const char *fp_xml_get(const struct fp_xml_node *e, const char *attr);
const char *fp_xml_text(const struct fp_xml_node *e);
int fp_xml_set(struct fp_xml_node *e, const char *attr, const char *value);
int fp_xml_set_text(struct fp_xml_node *e, const char *text);
struct fp_xml_node *fp_xml_add(struct fp_xml_node *parent, const char *name);
int fp_xml_write(const struct fp_xml_doc *d, struct fp_buf *out);
void fp_xml_free(struct fp_xml_doc *d);

#endif
