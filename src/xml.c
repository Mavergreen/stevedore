#define _POSIX_C_SOURCE 200809L

#include "xml.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_DEPTH 256
#define INDENT 4

struct parser {
	const char *start, *p, *end, *name;
};

static int
oom(void)
{
	fputs("stevedore: out of memory\n", stderr);
	return -1;
}

static int
bad(const struct parser *ps, const char *what)
{
	unsigned long line = 1;
	const char *q;

	for (q = ps->start; q < ps->p && q < ps->end; q++)
		line += *q == '\n';
	fprintf(stderr, "stevedore: %s: %s at line %lu\n", ps->name, what, line);
	return 2;
}

static char *
dup_n(const char *s, size_t n)
{
	char *d = malloc(n + 1);

	if (d != NULL) {
		memcpy(d, s, n);
		d[n] = '\0';
	}
	return d;
}

static int
valid_text(const unsigned char *s, size_t n)
{
	size_t i = 0;
	unsigned long c, min;
	int more;

	while (i < n) {
		if (s[i] < 0x80) {
			if ((s[i] < 0x20 && s[i] != '\t' && s[i] != '\n') || s[i] == 0x7f)
				return 0;
			i++;
			continue;
		}
		if ((s[i] & 0xe0) == 0xc0) {
			c = s[i] & 0x1f;
			more = 1;
			min = 0x80;
		} else if ((s[i] & 0xf0) == 0xe0) {
			c = s[i] & 0x0f;
			more = 2;
			min = 0x800;
		} else if ((s[i] & 0xf8) == 0xf0) {
			c = s[i] & 0x07;
			more = 3;
			min = 0x10000;
		} else {
			return 0;
		}
		for (i++; more > 0; more--, i++) {
			if (i >= n || (s[i] & 0xc0) != 0x80)
				return 0;
			c = c << 6 | (s[i] & 0x3f);
		}
		if (c < min || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff) || c == 0xfffe || c == 0xffff)
			return 0;
	}
	return 1;
}

static int
is_space(char c)
{
	return c == ' ' || c == '\t' || c == '\n';
}

static int
name_start(char c)
{
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == ':' || (unsigned char)c >= 0x80;
}

static int
name_char(char c)
{
	return name_start(c) || (c >= '0' && c <= '9') || c == '-' || c == '.';
}

static int
starts(const struct parser *ps, const char *s)
{
	size_t n = strlen(s);

	return (size_t)(ps->end - ps->p) >= n && memcmp(ps->p, s, n) == 0;
}

static void
skip_space(struct parser *ps)
{
	while (ps->p < ps->end && is_space(*ps->p))
		ps->p++;
}

static int
name(struct parser *ps, const char **s, size_t *n)
{
	*s = ps->p;
	if (ps->p >= ps->end || !name_start(*ps->p))
		return bad(ps, "a name expected");
	while (ps->p < ps->end && name_char(*ps->p))
		ps->p++;
	*n = (size_t)(ps->p - *s);
	return 0;
}

static int
put_utf8(struct fp_buf *b, unsigned long c)
{
	unsigned char u[4];
	size_t n;

	if (c < 0x80) {
		u[0] = (unsigned char)c;
		n = 1;
	} else if (c < 0x800) {
		u[0] = (unsigned char)(0xc0 | c >> 6);
		u[1] = (unsigned char)(0x80 | (c & 0x3f));
		n = 2;
	} else if (c < 0x10000) {
		u[0] = (unsigned char)(0xe0 | c >> 12);
		u[1] = (unsigned char)(0x80 | (c >> 6 & 0x3f));
		u[2] = (unsigned char)(0x80 | (c & 0x3f));
		n = 3;
	} else {
		u[0] = (unsigned char)(0xf0 | c >> 18);
		u[1] = (unsigned char)(0x80 | (c >> 12 & 0x3f));
		u[2] = (unsigned char)(0x80 | (c >> 6 & 0x3f));
		u[3] = (unsigned char)(0x80 | (c & 0x3f));
		n = 4;
	}
	return fp_buf_append(b, u, n);
}

static int
reference(struct parser *ps, const char *s, const char *e, struct fp_buf *out, const char **next)
{
	static const char *const names[] = { "lt;", "gt;", "amp;", "quot;", "apos;" };
	static const char chars[] = "<>&\"'";
	unsigned long c = 0;
	const char *q = s + 1;
	int i, base = 10, digits = 0, d;

	for (i = 0; i < 5; i++) {
		size_t l = strlen(names[i]);

		if ((size_t)(e - q) >= l && memcmp(q, names[i], l) == 0) {
			*next = q + l;
			return fp_buf_append(out, &chars[i], 1) ? oom() : 0;
		}
	}
	if (q >= e || *q != '#')
		return bad(ps, "an entity other than lt, gt, amp, quot, apos or a character reference");
	if (++q < e && *q == 'x') {
		base = 16;
		q++;
	}
	for (; q < e && *q != ';'; q++, digits++) {
		d = *q >= '0' && *q <= '9' ? *q - '0' : base == 16 && *q >= 'a' && *q <= 'f' ? *q - 'a' + 10
		    : base == 16 && *q >= 'A' && *q <= 'F' ? *q - 'A' + 10 : -1;
		if (d < 0 || digits > 8)
			return bad(ps, "a malformed character reference");
		c = c * (unsigned long)base + (unsigned long)d;
	}
	if (q >= e || digits == 0)
		return bad(ps, "a malformed character reference");
	if (!(c == '\t' || c == '\n' || (c >= 0x20 && c <= 0xd7ff && c != 0x7f) || (c >= 0xe000 && c <= 0xfffd)
	    || (c >= 0x10000 && c <= 0x10ffff)))
		return bad(ps, "a character reference to a character this writer does not keep");
	*next = q + 1;
	return put_utf8(out, c) ? oom() : 0;
}

static int
decode(struct parser *ps, const char *s, const char *e, int in_attr, struct fp_buf *out)
{
	const char *next;
	char sp = ' ';
	int rc;

	while (s < e) {
		if (*s == '&') {
			if ((rc = reference(ps, s, e, out, &next)) != 0)
				return rc;
			s = next;
		} else if (in_attr && *s == '<') {
			return bad(ps, "a < in an attribute value");
		} else if (in_attr && is_space(*s)) {
			if (fp_buf_append(out, &sp, 1))
				return oom();
			s++;
		} else {
			if (fp_buf_append(out, s, 1))
				return oom();
			s++;
		}
	}
	return fp_buf_append(out, "", 1) ? oom() : 0;
}

static void
node_free(struct fp_xml_node *n)
{
	size_t i;

	if (n == NULL)
		return;
	for (i = 0; i < n->nattr; i++) {
		free(n->attr[i].name);
		free(n->attr[i].value);
	}
	for (i = 0; i < n->nchild; i++)
		node_free(n->child[i]);
	free(n->attr);
	free(n->child);
	free(n->name);
	free(n->text);
	free(n);
}

static int
adopt(struct fp_xml_node *parent, struct fp_xml_node *c)
{
	struct fp_xml_node **grown;
	size_t cap;

	if (parent->nchild == parent->capchild) {
		cap = parent->capchild ? parent->capchild * 2 : 4;
		if ((grown = realloc(parent->child, cap * sizeof *grown)) == NULL)
			return -1;
		parent->child = grown;
		parent->capchild = cap;
	}
	parent->child[parent->nchild++] = c;
	return 0;
}

static struct fp_xml_node *
new_node(int kind, const char *s, size_t n)
{
	struct fp_xml_node *e = calloc(1, sizeof *e);

	if (e == NULL)
		return NULL;
	e->kind = kind;
	if ((kind == FP_XML_ELEMENT ? (e->name = dup_n(s, n)) : (e->text = dup_n(s, n))) == NULL) {
		free(e);
		return NULL;
	}
	return e;
}

static int
add_attr(struct fp_xml_node *e, const char *s, size_t n, struct fp_buf *value)
{
	struct fp_xml_attr *grown;
	size_t cap;

	if (e->nattr == e->capattr) {
		cap = e->capattr ? e->capattr * 2 : 4;
		if ((grown = realloc(e->attr, cap * sizeof *grown)) == NULL)
			return -1;
		e->attr = grown;
		e->capattr = cap;
	}
	if ((e->attr[e->nattr].name = dup_n(s, n)) == NULL)
		return -1;
	e->attr[e->nattr++].value = (char *)value->p;
	memset(value, 0, sizeof *value);
	return 0;
}

static int element(struct parser *ps, int depth, struct fp_xml_node **out);

static int
attributes(struct parser *ps, struct fp_xml_node *e, int decl)
{
	struct fp_buf v = { 0 };
	const char *s, *q;
	size_t n, i;
	char quote;
	int rc;

	for (;;) {
		q = ps->p;
		skip_space(ps);
		if (decl ? starts(ps, "?>") : starts(ps, "/>") || starts(ps, ">"))
			return 0;
		if (ps->p == q)
			return bad(ps, "a space expected before an attribute");
		if ((rc = name(ps, &s, &n)) != 0)
			return rc;
		for (i = 0; i < e->nattr; i++)
			if (strlen(e->attr[i].name) == n && memcmp(e->attr[i].name, s, n) == 0)
				return bad(ps, "a duplicate attribute");
		skip_space(ps);
		if (ps->p >= ps->end || *ps->p != '=')
			return bad(ps, "an = expected after an attribute name");
		ps->p++;
		skip_space(ps);
		if (ps->p >= ps->end || (*ps->p != '"' && *ps->p != '\''))
			return bad(ps, "a quoted attribute value expected");
		quote = *ps->p++;
		if ((q = memchr(ps->p, quote, (size_t)(ps->end - ps->p))) == NULL)
			return bad(ps, "an unterminated attribute value");
		if ((rc = decode(ps, ps->p, q, 1, &v)) != 0 || (rc = add_attr(e, s, n, &v) ? oom() : 0) != 0) {
			fp_buf_free(&v);
			return rc;
		}
		ps->p = q + 1;
	}
}

static int
only_space(const char *s)
{
	for (; *s != '\0'; s++)
		if (!is_space(*s))
			return 0;
	return 1;
}

static int
content(struct parser *ps, int depth, struct fp_xml_node *e)
{
	struct fp_buf text = { 0 };
	struct fp_xml_node *c;
	const char *s, *q;
	size_t n, before;
	int rc = 0, has_text = 0, has_other = 0;

	for (;;) {
		if (ps->p >= ps->end) {
			rc = bad(ps, "an unterminated element");
			break;
		}
		if (starts(ps, "</")) {
			ps->p += 2;
			if ((rc = name(ps, &s, &n)) != 0)
				break;
			if (n != strlen(e->name) || memcmp(s, e->name, n) != 0) {
				rc = bad(ps, "a closing tag that does not match");
				break;
			}
			skip_space(ps);
			if (ps->p >= ps->end || *ps->p != '>') {
				rc = bad(ps, "a > expected");
				break;
			}
			ps->p++;
			break;
		}
		if (starts(ps, "<!--")) {
			s = ps->p + 4;
			for (q = s; q + 3 <= ps->end && memcmp(q, "-->", 3) != 0; q++)
				if (q + 1 < ps->end && q[0] == '-' && q[1] == '-')
					break;
			if (q + 3 > ps->end || memcmp(q, "-->", 3) != 0) {
				rc = bad(ps, "a malformed comment");
				break;
			}
			if ((c = new_node(FP_XML_COMMENT, s, (size_t)(q - s))) == NULL || adopt(e, c) != 0) {
				node_free(c);
				rc = oom();
				break;
			}
			ps->p = q + 3;
			has_other = 1;
			continue;
		}
		if (starts(ps, "<![CDATA[")) {
			rc = bad(ps, "a CDATA section, which this writer does not keep");
			break;
		}
		if (starts(ps, "<?") || starts(ps, "<!")) {
			rc = bad(ps, "a processing instruction or declaration inside the document");
			break;
		}
		if (*ps->p == '<') {
			if ((rc = element(ps, depth + 1, &c)) != 0)
				break;
			if (adopt(e, c) != 0) {
				node_free(c);
				rc = oom();
				break;
			}
			has_other = 1;
			continue;
		}
		q = memchr(ps->p, '<', (size_t)(ps->end - ps->p));
		if (q == NULL)
			q = ps->end;
		before = text.len;
		if ((rc = decode(ps, ps->p, q, 0, &text)) != 0)
			break;
		text.len--;
		if (!only_space((const char *)text.p + before))
			has_text = 1;
		ps->p = q;
	}
	if (rc == 0 && has_text && has_other)
		rc = bad(ps, "mixed content, text beside elements or comments, which this writer does not keep");
	if (rc == 0 && has_text) {
		if ((c = new_node(FP_XML_TEXT, (const char *)text.p, text.len)) == NULL || adopt(e, c) != 0) {
			node_free(c);
			rc = oom();
		}
	}
	fp_buf_free(&text);
	return rc;
}

static int
element(struct parser *ps, int depth, struct fp_xml_node **out)
{
	struct fp_xml_node *e;
	const char *s;
	size_t n;
	int rc;

	*out = NULL;
	if (depth > MAX_DEPTH)
		return bad(ps, "elements nested too deeply");
	if (ps->p >= ps->end || *ps->p != '<')
		return bad(ps, "an element expected");
	ps->p++;
	if ((rc = name(ps, &s, &n)) != 0)
		return rc;
	if ((e = new_node(FP_XML_ELEMENT, s, n)) == NULL)
		return oom();
	if ((rc = attributes(ps, e, 0)) == 0) {
		if (starts(ps, "/>")) {
			ps->p += 2;
		} else {
			ps->p++;
			rc = content(ps, depth, e);
		}
	}
	if (rc != 0) {
		node_free(e);
		return rc;
	}
	*out = e;
	return 0;
}

static int
ascii_ieq(const char *a, const char *b)
{
	for (; *a != '\0' && *b != '\0'; a++, b++)
		if ((*a | 0x20) != (*b | 0x20))
			return 0;
	return *a == *b;
}

static int
declaration(struct parser *ps, struct fp_xml_doc *d)
{
	struct fp_xml_node tmp;
	size_t i;
	int rc;

	memset(&tmp, 0, sizeof tmp);
	ps->p += 5;
	rc = attributes(ps, &tmp, 1);
	for (i = 0; rc == 0 && i < tmp.nattr; i++) {
		const char *k = tmp.attr[i].name;
		char *v = tmp.attr[i].value;

		if (strcmp(k, "version") == 0 && strcmp(v, "1.0") != 0)
			rc = bad(ps, "an XML version other than 1.0");
		else if (strcmp(k, "encoding") == 0 && !ascii_ieq(v, "utf-8"))
			rc = bad(ps, "an encoding other than UTF-8");
		else if (strcmp(k, "standalone") == 0 && strcmp(v, "yes") != 0 && strcmp(v, "no") != 0)
			rc = bad(ps, "a standalone other than yes or no");
		else if (strcmp(k, "encoding") == 0)
			d->encoding = v, tmp.attr[i].value = NULL;
		else if (strcmp(k, "standalone") == 0)
			d->standalone = v, tmp.attr[i].value = NULL;
		else if (strcmp(k, "version") != 0)
			rc = bad(ps, "an unknown XML declaration attribute");
	}
	if (rc == 0 && (tmp.nattr == 0 || strcmp(tmp.attr[0].name, "version") != 0))
		rc = bad(ps, "an XML declaration without its version first");
	for (i = 0; i < tmp.nattr; i++) {
		free(tmp.attr[i].name);
		free(tmp.attr[i].value);
	}
	free(tmp.attr);
	if (rc == 0) {
		ps->p += 2;
		d->has_decl = 1;
	}
	return rc;
}

int
fp_xml_parse(const unsigned char *data, size_t n, const char *docname, struct fp_xml_doc *d)
{
	struct fp_buf norm = { 0 };
	struct parser ps;
	size_t i;
	int rc = 0;

	memset(d, 0, sizeof *d);
	if (fp_buf_reserve(&norm, n + 1) != 0)
		return oom();
	for (i = 0; i < n; i++) {
		if (data[i] == '\r') {
			norm.p[norm.len++] = '\n';
			if (i + 1 < n && data[i + 1] == '\n')
				i++;
		} else {
			norm.p[norm.len++] = data[i];
		}
	}
	ps.start = ps.p = (const char *)norm.p;
	ps.end = ps.p + norm.len;
	ps.name = docname;
	if (!valid_text(norm.p, norm.len))
		rc = bad(&ps, "bytes that are not UTF-8 text without control characters");
	if (rc == 0 && starts(&ps, "<?xml") && ps.p + 5 < ps.end && is_space(ps.p[5]))
		rc = declaration(&ps, d);
	if (rc == 0) {
		skip_space(&ps);
		if (starts(&ps, "<!") || starts(&ps, "<?"))
			rc = bad(&ps, "a comment, DOCTYPE or processing instruction outside the root element");
	}
	if (rc == 0 && (rc = element(&ps, 0, &d->root)) == 0) {
		skip_space(&ps);
		if (ps.p != ps.end)
			rc = bad(&ps, "something after the root element");
	}
	fp_buf_free(&norm);
	if (rc != 0)
		fp_xml_free(d);
	return rc;
}

const char *
fp_xml_get(const struct fp_xml_node *e, const char *attr)
{
	size_t i;

	for (i = 0; i < e->nattr; i++)
		if (strcmp(e->attr[i].name, attr) == 0)
			return e->attr[i].value;
	return NULL;
}

const char *
fp_xml_text(const struct fp_xml_node *e)
{
	if (e->nchild == 0)
		return "";
	if (e->nchild == 1 && e->child[0]->kind == FP_XML_TEXT)
		return e->child[0]->text;
	return NULL;
}

int
fp_xml_set(struct fp_xml_node *e, const char *attr, const char *value)
{
	struct fp_buf v = { 0 };
	size_t i;
	char *s;

	for (i = 0; i < e->nattr; i++) {
		if (strcmp(e->attr[i].name, attr) == 0) {
			if ((s = dup_n(value, strlen(value))) == NULL)
				return oom();
			free(e->attr[i].value);
			e->attr[i].value = s;
			return 0;
		}
	}
	if (fp_buf_append(&v, value, strlen(value) + 1) != 0 || add_attr(e, attr, strlen(attr), &v) != 0) {
		fp_buf_free(&v);
		return oom();
	}
	return 0;
}

int
fp_xml_set_text(struct fp_xml_node *e, const char *text)
{
	struct fp_xml_node *c;
	size_t i;

	if ((c = new_node(FP_XML_TEXT, text, strlen(text))) == NULL)
		return oom();
	for (i = 0; i < e->nchild; i++)
		node_free(e->child[i]);
	e->nchild = 0;
	if (adopt(e, c) != 0) {
		node_free(c);
		return oom();
	}
	return 0;
}

struct fp_xml_node *
fp_xml_add(struct fp_xml_node *parent, const char *elname)
{
	struct fp_xml_node *c = new_node(FP_XML_ELEMENT, elname, strlen(elname));

	if (c == NULL || adopt(parent, c) != 0) {
		node_free(c);
		oom();
		return NULL;
	}
	return c;
}

static int
put(struct fp_buf *b, const char *s)
{
	return fp_buf_append(b, s, strlen(s));
}

static int
escaped(struct fp_buf *b, const char *s, int in_attr)
{
	const char *r;

	for (; *s != '\0'; s++) {
		r = *s == '&' ? "&amp;" : *s == '<' ? "&lt;" : in_attr && *s == '"' ? "&quot;" : !in_attr && *s == '>' ? "&gt;" : NULL;
		if (r != NULL ? put(b, r) : fp_buf_append(b, s, 1))
			return -1;
	}
	return 0;
}

static int
indent(struct fp_buf *b, int depth)
{
	if (fp_buf_reserve(b, (size_t)depth * INDENT) != 0)
		return -1;
	memset(b->p + b->len, ' ', (size_t)depth * INDENT);
	b->len += (size_t)depth * INDENT;
	return 0;
}

static int
write_node(struct fp_buf *b, const struct fp_xml_node *n, int depth)
{
	size_t i;

	if (indent(b, depth))
		return -1;
	if (n->kind == FP_XML_COMMENT)
		return put(b, "<!--") || put(b, n->text) || put(b, "-->");
	if (n->kind == FP_XML_TEXT)
		return escaped(b, n->text, 0);
	if (put(b, "<") || put(b, n->name))
		return -1;
	for (i = 0; i < n->nattr; i++)
		if (put(b, " ") || put(b, n->attr[i].name) || put(b, "=\"") || escaped(b, n->attr[i].value, 1) || put(b, "\""))
			return -1;
	if (n->nchild == 0)
		return put(b, "/>");
	if (n->nchild == 1 && n->child[0]->kind == FP_XML_TEXT)
		return put(b, ">") || escaped(b, n->child[0]->text, 0) || put(b, "</") || put(b, n->name) || put(b, ">");
	if (put(b, ">\n"))
		return -1;
	for (i = 0; i < n->nchild; i++)
		if (write_node(b, n->child[i], depth + 1) || put(b, "\n"))
			return -1;
	return indent(b, depth) || put(b, "</") || put(b, n->name) || put(b, ">");
}

int
fp_xml_write(const struct fp_xml_doc *d, struct fp_buf *out)
{
	size_t start = out->len;

	if (put(out, "<?xml version=\"1.0\"")
	    || (d->encoding != NULL && (put(out, " encoding=\"") || put(out, d->encoding) || put(out, "\"")))
	    || put(out, " standalone=\"") || put(out, d->has_decl ? d->standalone != NULL ? d->standalone : "yes" : "no")
	    || put(out, "\"?>\n") || write_node(out, d->root, 0)) {
		out->len = start;
		return oom();
	}
	return 0;
}

void
fp_xml_free(struct fp_xml_doc *d)
{
	node_free(d->root);
	free(d->encoding);
	free(d->standalone);
	memset(d, 0, sizeof *d);
}
