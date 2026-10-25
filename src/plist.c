#include "plist.h"

#include <errno.h>
#include <float.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_DEPTH 512
#define DAYS_1970_TO_2001 11323LL
#define MAX_DATE_SECONDS 3e11

enum { P_STRING, P_INTEGER, P_REAL, P_BOOL, P_DATE, P_DATA, P_ARRAY, P_DICT };

static const char *const type_names[] = { "string", "integer", "real", "bool", "date", "data", "array", "dict" };

struct str {
	char *s;
	size_t len;
};

struct node {
	int type;
	int uns;
	unsigned long long u;
	double r;
	struct str v;
	struct str *key;
	struct node **kid;
	size_t n, cap;
};

struct fp_plist {
	struct node *root;
	char *name;
	struct fp_buf *scratch;
};

struct ctx {
	const char *name;
	int failed;
	size_t nodes, budget;
};

static int
bad(struct ctx *c, const char *fmt, ...)
{
	va_list ap;

	if (!c->failed) {
		fprintf(stderr, "stevedore: %s: ", c->name);
		va_start(ap, fmt);
		vfprintf(stderr, fmt, ap);
		va_end(ap);
		fputc('\n', stderr);
	}
	c->failed = 1;
	return -1;
}

static void
node_free(struct node *n)
{
	size_t i;

	if (n == NULL)
		return;
	for (i = 0; i < n->n; i++) {
		node_free(n->kid[i]);
		if (n->key != NULL)
			free(n->key[i].s);
	}
	free(n->kid);
	free(n->key);
	free(n->v.s);
	free(n);
}

static struct node *
node_new(struct ctx *c, int type)
{
	struct node *n;

	if (++c->nodes > c->budget) {
		bad(c, "more objects than %lu bytes of plist can hold", (unsigned long)c->budget);
		return NULL;
	}
	if ((n = calloc(1, sizeof *n)) == NULL) {
		bad(c, "out of memory");
		return NULL;
	}
	n->type = type;
	return n;
}

static int
str_take(struct fp_buf *b, struct str *s)
{
	if (fp_buf_append(b, "", 1) != 0)
		return -1;
	s->s = (char *)b->p;
	s->len = b->len - 1;
	b->p = NULL;
	b->len = b->cap = 0;
	return 0;
}

static int
str_dup(const char *p, size_t n, struct str *s)
{
	if ((s->s = malloc(n + 1)) == NULL)
		return -1;
	memcpy(s->s, p, n);
	s->s[n] = '\0';
	s->len = n;
	return 0;
}

static size_t
dict_find(const struct node *d, const char *k, size_t klen)
{
	size_t i;

	for (i = 0; i < d->n; i++)
		if (d->key[i].len == klen && memcmp(d->key[i].s, k, klen) == 0)
			return i;
	return (size_t)-1;
}

static int
node_push(struct node *parent, struct str *key, struct node *kid)
{
	size_t i, cap;
	void *p;

	if (key != NULL && (i = dict_find(parent, key->s, key->len)) != (size_t)-1) {
		node_free(parent->kid[i]);
		parent->kid[i] = kid;
		free(key->s);
		return 0;
	}
	if (parent->n == parent->cap) {
		cap = parent->cap ? parent->cap * 2 : 8;
		if ((p = realloc(parent->kid, cap * sizeof *parent->kid)) == NULL)
			return -1;
		parent->kid = p;
		if (parent->type == P_DICT) {
			if ((p = realloc(parent->key, cap * sizeof *parent->key)) == NULL)
				return -1;
			parent->key = p;
		}
		parent->cap = cap;
	}
	parent->kid[parent->n] = kid;
	if (key != NULL)
		parent->key[parent->n] = *key;
	parent->n++;
	return 0;
}

static unsigned long
utf8_next(const unsigned char **pp, const unsigned char *end)
{
	const unsigned char *p = *pp;
	unsigned long cp;
	int more, i;

	if (*p < 0x80) {
		*pp = p + 1;
		return *p;
	}
	if ((*p & 0xE0) == 0xC0) {
		cp = *p & 0x1F;
		more = 1;
	} else if ((*p & 0xF0) == 0xE0) {
		cp = *p & 0x0F;
		more = 2;
	} else if ((*p & 0xF8) == 0xF0) {
		cp = *p & 0x07;
		more = 3;
	} else {
		*pp = p + 1;
		return 0xFFFFFFFFUL;
	}
	if (end - p <= more) {
		*pp = p + 1;
		return 0xFFFFFFFFUL;
	}
	for (i = 1; i <= more; i++) {
		if ((p[i] & 0xC0) != 0x80) {
			*pp = p + 1;
			return 0xFFFFFFFFUL;
		}
		cp = cp << 6 | (p[i] & 0x3F);
	}
	*pp = p + more + 1;
	if ((more == 1 && cp < 0x80) || (more == 2 && cp < 0x800) || (more == 3 && cp < 0x10000)
	    || (cp >= 0xD800 && cp <= 0xDFFF) || cp > 0x10FFFF)
		return 0xFFFFFFFFUL;
	return cp;
}

static int
utf8_valid(const unsigned char *p, size_t n, int allow_nul)
{
	const unsigned char *end = p + n;
	unsigned long cp;

	while (p < end) {
		cp = utf8_next(&p, end);
		if (cp == 0xFFFFFFFFUL || (cp == 0 && !allow_nul))
			return 0;
	}
	return 1;
}

static int
utf8_put(struct fp_buf *b, unsigned long cp)
{
	unsigned char c[4];
	size_t n;

	if (cp < 0x80) {
		c[0] = (unsigned char)cp;
		n = 1;
	} else if (cp < 0x800) {
		c[0] = (unsigned char)(0xC0 | cp >> 6);
		c[1] = (unsigned char)(0x80 | (cp & 0x3F));
		n = 2;
	} else if (cp < 0x10000) {
		c[0] = (unsigned char)(0xE0 | cp >> 12);
		c[1] = (unsigned char)(0x80 | (cp >> 6 & 0x3F));
		c[2] = (unsigned char)(0x80 | (cp & 0x3F));
		n = 3;
	} else {
		c[0] = (unsigned char)(0xF0 | cp >> 18);
		c[1] = (unsigned char)(0x80 | (cp >> 12 & 0x3F));
		c[2] = (unsigned char)(0x80 | (cp >> 6 & 0x3F));
		c[3] = (unsigned char)(0x80 | (cp & 0x3F));
		n = 4;
	}
	return fp_buf_append(b, c, n);
}

static long long
s64(unsigned long long u)
{
	u &= 0xFFFFFFFFFFFFFFFFULL;
	return u <= 0x7FFFFFFFFFFFFFFFULL ? (long long)u : -(long long)(~u & 0x7FFFFFFFFFFFFFFFULL) - 1;
}

static int
parse_int(const char *s, int *uns, unsigned long long *u)
{
	unsigned long long mag = 0, max = 0xFFFFFFFFFFFFFFFFULL;
	int neg = 0, base = 10, d, any = 0;

	if (*s == '+' || *s == '-')
		neg = *s++ == '-';
	if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
		base = 16;
		s += 2;
	}
	for (; *s != '\0'; s++, any = 1) {
		if (*s >= '0' && *s <= '9')
			d = *s - '0';
		else if (base == 16 && *s >= 'a' && *s <= 'f')
			d = *s - 'a' + 10;
		else if (base == 16 && *s >= 'A' && *s <= 'F')
			d = *s - 'A' + 10;
		else
			return -1;
		if (mag > (max - (unsigned long long)d) / (unsigned long long)base)
			return -1;
		mag = mag * (unsigned long long)base + (unsigned long long)d;
	}
	if (!any)
		return -1;
	if (neg) {
		if (mag > 0x8000000000000000ULL)
			return -1;
		*u = (0 - mag) & max;
		*uns = 0;
	} else {
		*u = mag;
		*uns = mag > 0x7FFFFFFFFFFFFFFFULL;
	}
	return 0;
}

static int
parse_real(const char *s, double *r)
{
	char *end;

	if (*s == '\0' || strpbrk(s, "xX") != NULL)
		return -1;
	errno = 0;
	*r = strtod(s, &end);
	return end == s || *end != '\0' ? -1 : 0;
}

static long long
days_from_civil(long long y, int m, int d)
{
	long long era, yoe, doy, doe;

	y -= m <= 2;
	era = (y >= 0 ? y : y - 399) / 400;
	yoe = y - era * 400;
	doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
	doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
	return era * 146097 + doe - 719468;
}

static void
civil_from_days(long long z, long long *y, int *m, int *d)
{
	long long era, doe, yoe, doy, mp;

	z += 719468;
	era = (z >= 0 ? z : z - 146096) / 146097;
	doe = z - era * 146097;
	yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
	doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
	mp = (5 * doy + 2) / 153;
	*d = (int)(doy - (153 * mp + 2) / 5 + 1);
	*m = (int)(mp < 10 ? mp + 3 : mp - 9);
	*y = yoe + era * 400 + (*m <= 2);
}

struct tm6 {
	long long year;
	int mon, day, hour, min, sec, wday;
};

static void
date_split(double r, struct tm6 *t)
{
	long long secs = (long long)r, days, rem;

	if ((double)secs > r)
		secs--;
	days = secs / 86400;
	rem = secs % 86400;
	if (rem < 0) {
		rem += 86400;
		days--;
	}
	days += DAYS_1970_TO_2001;
	civil_from_days(days, &t->year, &t->mon, &t->day);
	t->hour = (int)(rem / 3600);
	t->min = (int)(rem / 60 % 60);
	t->sec = (int)(rem % 60);
	t->wday = (int)(((days + 4) % 7 + 7) % 7);
}

static int
two(const char *s, int *v)
{
	if (s[0] < '0' || s[0] > '9' || s[1] < '0' || s[1] > '9')
		return -1;
	*v = (s[0] - '0') * 10 + (s[1] - '0');
	return 0;
}

static int
parse_date(const char *s, double *r)
{
	static const int mdays[] = { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
	int yh, yl, mo, d, h, mi, se;
	long long y;

	if (strlen(s) != 20 || s[4] != '-' || s[7] != '-' || s[10] != 'T' || s[13] != ':' || s[16] != ':'
	    || s[19] != 'Z' || two(s, &yh) || two(s + 2, &yl) || two(s + 5, &mo) || two(s + 8, &d)
	    || two(s + 11, &h) || two(s + 14, &mi) || two(s + 17, &se))
		return -1;
	y = yh * 100 + yl;
	if (mo < 1 || mo > 12 || d < 1 || d > mdays[mo - 1] || h > 23 || mi > 59 || se > 59)
		return -1;
	if (mo == 2 && d == 29 && !(y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)))
		return -1;
	*r = (double)((days_from_civil(y, mo, d) - DAYS_1970_TO_2001) * 86400 + h * 3600 + mi * 60 + se);
	return 0;
}

static int
b64_val(int c)
{
	if (c >= 'A' && c <= 'Z')
		return c - 'A';
	if (c >= 'a' && c <= 'z')
		return c - 'a' + 26;
	if (c >= '0' && c <= '9')
		return c - '0' + 52;
	if (c == '+')
		return 62;
	if (c == '/')
		return 63;
	return -1;
}

static int
parse_data(const struct str *in, struct fp_buf *out)
{
	unsigned long acc = 0;
	int bits = 0, v, pad = 0;
	size_t i;
	unsigned char c;

	for (i = 0; i < in->len; i++) {
		c = (unsigned char)in->s[i];
		if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
			continue;
		if (c == '=') {
			pad = 1;
			continue;
		}
		if (pad || (v = b64_val(c)) < 0)
			return -1;
		acc = (acc << 6 | (unsigned long)v) & 0xFFFFFF;
		bits += 6;
		if (bits >= 8) {
			bits -= 8;
			c = (unsigned char)(acc >> bits);
			if (fp_buf_append(out, &c, 1) != 0)
				return -1;
		}
	}
	return bits >= 6 ? -1 : 0;
}

struct xml {
	struct ctx *c;
	const unsigned char *p, *end;
};

static int
starts(const struct xml *x, const char *s)
{
	size_t n = strlen(s);

	return (size_t)(x->end - x->p) >= n && memcmp(x->p, s, n) == 0;
}

static int
skip_past(struct xml *x, const char *s)
{
	size_t n = strlen(s);

	for (; (size_t)(x->end - x->p) >= n; x->p++)
		if (memcmp(x->p, s, n) == 0) {
			x->p += n;
			return 0;
		}
	return bad(x->c, "unterminated %s", s);
}

static void
skip_ws(struct xml *x)
{
	while (x->p < x->end && (*x->p == ' ' || *x->p == '\t' || *x->p == '\r' || *x->p == '\n'))
		x->p++;
}

static int
skip_misc(struct xml *x)
{
	for (;;) {
		skip_ws(x);
		if (starts(x, "<!--")) {
			if (skip_past(x, "-->") != 0)
				return -1;
		} else if (starts(x, "<?")) {
			if (skip_past(x, "?>") != 0)
				return -1;
		} else {
			return 0;
		}
	}
}

static int
skip_doctype(struct xml *x)
{
	int depth = 0;
	unsigned char q = 0;

	for (; x->p < x->end; x->p++) {
		if (q != 0) {
			if (*x->p == q)
				q = 0;
		} else if (*x->p == '"' || *x->p == '\'') {
			q = *x->p;
		} else if (*x->p == '[') {
			depth++;
		} else if (*x->p == ']') {
			depth--;
		} else if (*x->p == '>' && depth <= 0) {
			x->p++;
			return 0;
		}
	}
	return bad(x->c, "unterminated <!DOCTYPE");
}

static int
name_char(unsigned char c)
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
	    || c == ':' || c == '.' || c == '-';
}

static int
open_tag(struct xml *x, char *name, size_t cap, int *empty)
{
	size_t n = 0;
	unsigned char q;

	if (x->p >= x->end || *x->p != '<')
		return bad(x->c, x->p >= x->end ? "unexpected end of file" : "unexpected text");
	for (x->p++; x->p < x->end && name_char(*x->p); x->p++)
		if (n + 1 < cap)
			name[n++] = (char)*x->p;
		else
			return bad(x->c, "unknown element");
	name[n] = '\0';
	if (n == 0)
		return bad(x->c, "malformed tag");
	for (;;) {
		skip_ws(x);
		if (starts(x, "/>")) {
			x->p += 2;
			*empty = 1;
			return 0;
		}
		if (starts(x, ">")) {
			x->p++;
			*empty = 0;
			return 0;
		}
		if (x->p >= x->end || !name_char(*x->p))
			return bad(x->c, "malformed <%s> tag", name);
		while (x->p < x->end && name_char(*x->p))
			x->p++;
		skip_ws(x);
		if (x->p >= x->end || *x->p != '=')
			return bad(x->c, "malformed <%s> tag", name);
		x->p++;
		skip_ws(x);
		if (x->p >= x->end || (*x->p != '"' && *x->p != '\''))
			return bad(x->c, "malformed <%s> tag", name);
		q = *x->p++;
		while (x->p < x->end && *x->p != q)
			x->p++;
		if (x->p >= x->end)
			return bad(x->c, "malformed <%s> tag", name);
		x->p++;
	}
}

static int
close_tag(struct xml *x, const char *name)
{
	size_t n = strlen(name);

	if (!starts(x, "</") || (size_t)(x->end - x->p) < n + 2 || memcmp(x->p + 2, name, n) != 0)
		return bad(x->c, "expected </%s>", name);
	x->p += n + 2;
	skip_ws(x);
	if (x->p >= x->end || *x->p != '>')
		return bad(x->c, "expected </%s>", name);
	x->p++;
	return 0;
}

static int
entity(struct xml *x, struct fp_buf *b)
{
	static const struct { const char *name; char c; } named[] = {
		{ "&amp;", '&' }, { "&lt;", '<' }, { "&gt;", '>' }, { "&quot;", '"' }, { "&apos;", '\'' },
	};
	unsigned long cp = 0;
	int hex, any = 0, d;
	size_t i;

	for (i = 0; i < sizeof named / sizeof named[0]; i++)
		if (starts(x, named[i].name)) {
			x->p += strlen(named[i].name);
			return fp_buf_append(b, &named[i].c, 1);
		}
	if (!starts(x, "&#"))
		return bad(x->c, "unknown entity");
	x->p += 2;
	hex = x->p < x->end && *x->p == 'x';
	x->p += hex;
	for (; x->p < x->end && *x->p != ';'; x->p++, any = 1) {
		if (*x->p >= '0' && *x->p <= '9')
			d = *x->p - '0';
		else if (hex && *x->p >= 'a' && *x->p <= 'f')
			d = *x->p - 'a' + 10;
		else if (hex && *x->p >= 'A' && *x->p <= 'F')
			d = *x->p - 'A' + 10;
		else
			return bad(x->c, "malformed character reference");
		cp = cp * (hex ? 16 : 10) + (unsigned long)d;
		if (cp > 0x10FFFF)
			return bad(x->c, "malformed character reference");
	}
	if (x->p >= x->end || !any || cp == 0 || (cp >= 0xD800 && cp <= 0xDFFF))
		return bad(x->c, "malformed character reference");
	x->p++;
	return utf8_put(b, cp);
}

static int
text(struct xml *x, const char *name, struct str *out)
{
	struct fp_buf b = { 0 };
	const unsigned char *s;

	for (;;) {
		if (x->p >= x->end) {
			fp_buf_free(&b);
			return bad(x->c, "unterminated <%s>", name);
		}
		if (*x->p == '<') {
			if (starts(x, "<![CDATA[")) {
				s = x->p += 9;
				if (skip_past(x, "]]>") != 0 || fp_buf_append(&b, s, (size_t)(x->p - 3 - s)) != 0)
					break;
			} else if (starts(x, "<!--")) {
				if (skip_past(x, "-->") != 0)
					break;
			} else if (starts(x, "</")) {
				if (close_tag(x, name) != 0)
					break;
				if (!utf8_valid(b.p, b.len, 0)) {
					bad(x->c, "<%s> is not UTF-8", name);
					break;
				}
				if (str_take(&b, out) != 0) {
					bad(x->c, "out of memory");
					break;
				}
				return 0;
			} else {
				bad(x->c, "unexpected element in <%s>", name);
				break;
			}
		} else if (*x->p == '&') {
			if (entity(x, &b) != 0)
				break;
		} else {
			s = x->p;
			while (x->p < x->end && *x->p != '<' && *x->p != '&')
				x->p++;
			if (fp_buf_append(&b, s, (size_t)(x->p - s)) != 0)
				break;
		}
	}
	fp_buf_free(&b);
	return bad(x->c, "out of memory");
}

static int xml_value(struct xml *x, int depth, struct node **out);

static int
xml_container(struct xml *x, int depth, const char *name, struct node *n)
{
	struct str key;
	struct node *kid;
	char tag[16];
	int empty;

	for (;;) {
		if (skip_misc(x) != 0)
			return -1;
		if (starts(x, "</"))
			return close_tag(x, name);
		key.s = NULL;
		if (n->type == P_DICT) {
			if (open_tag(x, tag, sizeof tag, &empty) != 0)
				return -1;
			if (strcmp(tag, "key") != 0)
				return bad(x->c, "expected <key> in <dict>, not <%s>", tag);
			if (empty ? str_dup("", 0, &key) != 0 : text(x, "key", &key) != 0)
				return x->c->failed ? -1 : bad(x->c, "out of memory");
			if (skip_misc(x) != 0) {
				free(key.s);
				return -1;
			}
		}
		if (xml_value(x, depth + 1, &kid) != 0) {
			free(key.s);
			return -1;
		}
		if (node_push(n, n->type == P_DICT ? &key : NULL, kid) != 0) {
			free(key.s);
			node_free(kid);
			return bad(x->c, "out of memory");
		}
	}
}

static int
xml_value(struct xml *x, int depth, struct node **out)
{
	struct node *n = NULL;
	struct str t = { 0 };
	struct fp_buf b = { 0 };
	char tag[16];
	int empty, rc = -1;

	if (depth > MAX_DEPTH)
		return bad(x->c, "nested more than %d deep", MAX_DEPTH);
	if (open_tag(x, tag, sizeof tag, &empty) != 0)
		return -1;
	if (strcmp(tag, "dict") == 0 || strcmp(tag, "array") == 0) {
		if ((n = node_new(x->c, tag[0] == 'd' ? P_DICT : P_ARRAY)) == NULL)
			return -1;
		rc = empty ? 0 : xml_container(x, depth, tag, n);
	} else if (strcmp(tag, "true") == 0 || strcmp(tag, "false") == 0) {
		if ((n = node_new(x->c, P_BOOL)) == NULL)
			return -1;
		n->u = tag[0] == 't';
		rc = 0;
		if (!empty) {
			skip_ws(x);
			rc = close_tag(x, tag);
		}
	} else if (strcmp(tag, "string") == 0) {
		if ((n = node_new(x->c, P_STRING)) == NULL)
			return -1;
		rc = empty ? str_dup("", 0, &n->v) : text(x, tag, &n->v);
		if (rc != 0 && !x->c->failed)
			bad(x->c, "out of memory");
	} else if (strcmp(tag, "integer") == 0 || strcmp(tag, "real") == 0 || strcmp(tag, "date") == 0
	    || strcmp(tag, "data") == 0) {
		if (empty && strcmp(tag, "data") != 0)
			return bad(x->c, "empty <%s>", tag);
		if (!empty && text(x, tag, &t) != 0)
			return -1;
		if (empty && str_dup("", 0, &t) != 0)
			return bad(x->c, "out of memory");
		if ((n = node_new(x->c, P_STRING)) == NULL) {
			free(t.s);
			return -1;
		}
		if (tag[0] == 'i') {
			n->type = P_INTEGER;
			rc = parse_int(t.s, &n->uns, &n->u);
		} else if (tag[0] == 'r') {
			n->type = P_REAL;
			rc = parse_real(t.s, &n->r);
		} else if (strcmp(tag, "date") == 0) {
			n->type = P_DATE;
			rc = parse_date(t.s, &n->r);
		} else {
			n->type = P_DATA;
			rc = parse_data(&t, &b) != 0 || str_take(&b, &n->v) != 0 ? -1 : 0;
			fp_buf_free(&b);
		}
		if (rc != 0)
			bad(x->c, "malformed <%s>%s</%s>", tag, strlen(t.s) > 40 ? "..." : t.s, tag);
		free(t.s);
	} else {
		return bad(x->c, "unknown element <%s>", tag);
	}
	if (rc != 0) {
		node_free(n);
		return -1;
	}
	*out = n;
	return 0;
}

static int
xml_parse(struct ctx *c, const unsigned char *p, size_t len, struct node **out)
{
	struct xml x;
	const unsigned char *at;
	char tag[16];
	int empty;

	x.c = c;
	x.p = p;
	x.end = p + len;
	if (starts(&x, "\xEF\xBB\xBF"))
		x.p += 3;
	if (skip_misc(&x) != 0)
		return -1;
	if (starts(&x, "<!DOCTYPE") && (skip_doctype(&x) != 0 || skip_misc(&x) != 0))
		return -1;
	if (x.p >= x.end || *x.p != '<')
		return bad(c, "not a plist");
	at = x.p;
	if (open_tag(&x, tag, sizeof tag, &empty) != 0)
		return -1;
	if (strcmp(tag, "plist") == 0) {
		if (empty)
			return bad(c, "empty <plist>");
		if (skip_misc(&x) != 0 || xml_value(&x, 0, out) != 0)
			return -1;
		if (skip_misc(&x) != 0 || close_tag(&x, "plist") != 0) {
			node_free(*out);
			return -1;
		}
	} else {
		x.p = at;
		if (xml_value(&x, 0, out) != 0)
			return -1;
	}
	if (skip_misc(&x) != 0 || x.p != x.end) {
		node_free(*out);
		return bad(c, "content after the plist");
	}
	return 0;
}

struct bin {
	struct ctx *c;
	const unsigned char *p;
	unsigned long long lim, nobj, otab;
	unsigned osz, rsz;
};

static unsigned long long
be(const unsigned char *p, unsigned n)
{
	unsigned long long v = 0;

	while (n-- > 0)
		v = v << 8 | *p++;
	return v;
}

static int
bin_count(struct bin *b, unsigned long long *pos, unsigned lo, unsigned long long *count)
{
	unsigned m, w;

	if (lo != 0xF) {
		*count = lo;
		return 0;
	}
	if (*pos >= b->lim)
		return bad(b->c, "truncated binary1 object");
	m = b->p[(*pos)++];
	if ((m & 0xF0) != 0x10 || (m & 0x0F) > 3)
		return bad(b->c, "malformed binary1 length");
	w = 1u << (m & 0x0F);
	if (b->lim - *pos < w)
		return bad(b->c, "truncated binary1 object");
	*count = be(b->p + *pos, w);
	*pos += w;
	return 0;
}

static int bin_obj(struct bin *b, unsigned long long ref, int depth, struct node **out);

static int
bin_container(struct bin *b, unsigned long long pos, unsigned long long count, int depth, struct node *n)
{
	unsigned long long i, per = n->type == P_DICT ? 2 : 1;
	struct node *k, *v;
	struct str key;

	if (count > (b->lim - pos) / b->rsz / per)
		return bad(b->c, "truncated binary1 %s", n->type == P_DICT ? "dict" : "array");
	for (i = 0; i < count; i++) {
		key.s = NULL;
		if (n->type == P_DICT) {
			if (bin_obj(b, be(b->p + pos + i * b->rsz, b->rsz), depth + 1, &k) != 0)
				return -1;
			if (k->type != P_STRING) {
				node_free(k);
				return bad(b->c, "binary1 dict key is not a string");
			}
			key = k->v;
			k->v.s = NULL;
			node_free(k);
			v = NULL;
			if (bin_obj(b, be(b->p + pos + (count + i) * b->rsz, b->rsz), depth + 1, &v) != 0) {
				free(key.s);
				return -1;
			}
		} else if (bin_obj(b, be(b->p + pos + i * b->rsz, b->rsz), depth + 1, &v) != 0) {
			return -1;
		}
		if (node_push(n, n->type == P_DICT ? &key : NULL, v) != 0) {
			free(key.s);
			node_free(v);
			return bad(b->c, "out of memory");
		}
	}
	return 0;
}

static double
f64(unsigned long long bits)
{
	uint64_t u = (uint64_t)bits;
	double d;

	memcpy(&d, &u, sizeof d);
	return d;
}

static double
f32(unsigned long long bits)
{
	uint32_t u = (uint32_t)bits;
	float f;

	memcpy(&f, &u, sizeof f);
	return (double)f;
}

static int
bin_utf16(struct bin *b, unsigned long long pos, unsigned long long count, struct str *out)
{
	struct fp_buf o = { 0 };
	unsigned long long i;
	unsigned long u, lo;

	for (i = 0; i < count; i++) {
		u = (unsigned long)be(b->p + pos + 2 * i, 2);
		if (u >= 0xD800 && u <= 0xDBFF && i + 1 < count
		    && (lo = (unsigned long)be(b->p + pos + 2 * (i + 1), 2)) >= 0xDC00 && lo <= 0xDFFF) {
			u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
			i++;
		} else if (u >= 0xD800 && u <= 0xDFFF) {
			fp_buf_free(&o);
			return bad(b->c, "binary1 string has an unpaired surrogate");
		}
		if (utf8_put(&o, u) != 0) {
			fp_buf_free(&o);
			return bad(b->c, "out of memory");
		}
	}
	if (str_take(&o, out) != 0) {
		fp_buf_free(&o);
		return bad(b->c, "out of memory");
	}
	return 0;
}

static int
bin_obj(struct bin *b, unsigned long long ref, int depth, struct node **out)
{
	unsigned long long off, pos, count, hi8, i;
	unsigned m, hi, lo, w;
	struct node *n;
	int rc = 0;

	if (depth > MAX_DEPTH)
		return bad(b->c, "binary1 objects nest more than %d deep, or refer to themselves", MAX_DEPTH);
	if (ref >= b->nobj)
		return bad(b->c, "binary1 object reference out of range");
	off = be(b->p + b->otab + ref * b->osz, b->osz);
	if (off < 8 || off >= b->lim)
		return bad(b->c, "binary1 object offset out of range");
	pos = off;
	m = b->p[pos++];
	hi = m >> 4;
	lo = m & 0x0F;
	switch (hi) {
	case 0x0:
		if (m != 0x08 && m != 0x09)
			return bad(b->c, "unsupported binary1 object 0x%02x", m);
		if ((n = node_new(b->c, P_BOOL)) == NULL)
			return -1;
		n->u = m == 0x09;
		break;
	case 0x1:
		if (lo > 4)
			return bad(b->c, "malformed binary1 integer");
		w = 1u << lo;
		if (b->lim - pos < w)
			return bad(b->c, "truncated binary1 integer");
		if ((n = node_new(b->c, P_INTEGER)) == NULL)
			return -1;
		if (w == 16) {
			hi8 = be(b->p + pos, 8);
			n->u = be(b->p + pos + 8, 8);
			if (hi8 == 0)
				n->uns = n->u > 0x7FFFFFFFFFFFFFFFULL;
			else if (!(hi8 == 0xFFFFFFFFFFFFFFFFULL && n->u > 0x7FFFFFFFFFFFFFFFULL))
				rc = bad(b->c, "binary1 integer out of range");
		} else {
			n->u = be(b->p + pos, w);
		}
		break;
	case 0x2:
	case 0x3:
		w = hi == 0x3 ? (m == 0x33 ? 8 : 0) : (lo == 2 ? 4 : lo == 3 ? 8 : 0);
		if (w == 0)
			return bad(b->c, "unsupported binary1 object 0x%02x", m);
		if (b->lim - pos < w)
			return bad(b->c, "truncated binary1 %s", hi == 0x3 ? "date" : "real");
		if ((n = node_new(b->c, hi == 0x3 ? P_DATE : P_REAL)) == NULL)
			return -1;
		n->r = w == 4 ? f32(be(b->p + pos, 4)) : f64(be(b->p + pos, 8));
		if (hi == 0x3 && !(n->r > -MAX_DATE_SECONDS && n->r < MAX_DATE_SECONDS))
			rc = bad(b->c, "binary1 date out of range");
		break;
	case 0x4:
	case 0x5:
	case 0x6:
		if (bin_count(b, &pos, lo, &count) != 0)
			return -1;
		if (count > (b->lim - pos) / (hi == 0x6 ? 2 : 1))
			return bad(b->c, "truncated binary1 %s", hi == 0x4 ? "data" : "string");
		if ((n = node_new(b->c, hi == 0x4 ? P_DATA : P_STRING)) == NULL)
			return -1;
		if (hi == 0x6) {
			rc = bin_utf16(b, pos, count, &n->v);
			break;
		}
		for (i = 0; hi == 0x5 && i < count; i++)
			if (b->p[pos + i] >= 0x80) {
				node_free(n);
				return bad(b->c, "binary1 ASCII string is not ASCII");
			}
		if (str_dup((const char *)b->p + pos, (size_t)count, &n->v) != 0)
			rc = bad(b->c, "out of memory");
		break;
	case 0xA:
	case 0xD:
		if (bin_count(b, &pos, lo, &count) != 0)
			return -1;
		if ((n = node_new(b->c, hi == 0xA ? P_ARRAY : P_DICT)) == NULL)
			return -1;
		rc = bin_container(b, pos, count, depth, n);
		break;
	default:
		return bad(b->c, "unsupported binary1 object 0x%02x", m);
	}
	if (rc != 0) {
		node_free(n);
		return -1;
	}
	*out = n;
	return 0;
}

static int
bin_parse(struct ctx *c, const unsigned char *p, size_t len, struct node **out)
{
	struct bin b;
	const unsigned char *t;
	unsigned long long top;

	if (len < 8 + 1 + 1 + 32)
		return bad(c, "truncated binary1 plist");
	t = p + len - 32;
	b.c = c;
	b.p = p;
	b.osz = t[6];
	b.rsz = t[7];
	b.nobj = be(t + 8, 8);
	top = be(t + 16, 8);
	b.otab = be(t + 24, 8);
	if (b.osz < 1 || b.osz > 8 || b.rsz < 1 || b.rsz > 8 || b.otab < 9 || b.otab > len - 32
	    || b.nobj == 0 || b.nobj > (len - 32 - b.otab) / b.osz || top >= b.nobj)
		return bad(c, "malformed binary1 trailer");
	b.lim = b.otab;
	return bin_obj(&b, top, 0, out);
}

int
fp_plist_parse(const unsigned char *data, size_t n, const char *name, struct fp_plist **out)
{
	struct ctx c;
	struct fp_plist *p;
	struct node *root = NULL;
	int rc;

	c.name = name;
	c.failed = 0;
	c.nodes = 0;
	c.budget = n;
	if (n >= 8 && memcmp(data, "bplist00", 8) == 0)
		rc = bin_parse(&c, data, n, &root);
	else if (n >= 6 && memcmp(data, "bplist", 6) == 0)
		rc = bad(&c, "unsupported binary plist version");
	else
		rc = xml_parse(&c, data, n, &root);
	if (rc != 0)
		return FP_PLIST_MALFORMED;
	if ((p = calloc(1, sizeof *p)) == NULL || (p->scratch = calloc(1, sizeof *p->scratch)) == NULL
	    || (p->name = malloc(strlen(name) + 1)) == NULL) {
		if (p != NULL)
			free(p->scratch);
		free(p);
		node_free(root);
		bad(&c, "out of memory");
		return FP_PLIST_MALFORMED;
	}
	strcpy(p->name, name);
	p->root = root;
	*out = p;
	return 0;
}

int
fp_plist_read(const char *path, struct fp_plist **out)
{
	struct fp_buf b = { 0 };
	FILE *f;
	size_t got;
	int rc, err = 0;

	if ((f = fopen(path, "rb")) == NULL) {
		fprintf(stderr, "stevedore: %s: %s\n", path, strerror(errno));
		return FP_PLIST_MALFORMED;
	}
	for (;;) {
		if (fp_buf_reserve(&b, 65536) != 0) {
			err = ENOMEM;
			break;
		}
		got = fread(b.p + b.len, 1, 65536, f);
		b.len += got;
		if (got < 65536) {
			if (ferror(f))
				err = errno ? errno : EIO;
			break;
		}
	}
	fclose(f);
	if (err != 0) {
		fprintf(stderr, "stevedore: %s: %s\n", path, strerror(err));
		fp_buf_free(&b);
		return FP_PLIST_MALFORMED;
	}
	rc = fp_plist_parse(b.p != NULL ? b.p : (const unsigned char *)"", b.len, path, out);
	fp_buf_free(&b);
	return rc;
}

void
fp_plist_free(struct fp_plist *p)
{
	if (p == NULL)
		return;
	node_free(p->root);
	fp_buf_free(p->scratch);
	free(p->scratch);
	free(p->name);
	free(p);
}

static struct node *
child(const struct node *n, const char *k, size_t klen, size_t *idx)
{
	size_t i, v = 0;

	if (n->type == P_DICT) {
		i = dict_find(n, k, klen);
		if (idx != NULL)
			*idx = i == (size_t)-1 ? n->n : i;
		return i == (size_t)-1 ? NULL : n->kid[i];
	}
	if (n->type != P_ARRAY || klen == 0 || klen > 18)
		return NULL;
	for (i = 0; i < klen; i++) {
		if (k[i] < '0' || k[i] > '9')
			return NULL;
		v = v * 10 + (size_t)(k[i] - '0');
	}
	if (idx != NULL)
		*idx = v;
	return v < n->n ? n->kid[v] : NULL;
}

static const char *
strip(const char *keypath)
{
	return *keypath == ':' ? keypath + 1 : keypath;
}

static struct node *
walk(struct node *n, const char *path, const char *stop)
{
	const char *e;

	while (n != NULL && path < stop) {
		e = memchr(path, ':', (size_t)(stop - path));
		if (e == NULL)
			e = stop;
		n = child(n, path, (size_t)(e - path), NULL);
		path = e < stop ? e + 1 : e;
	}
	return n;
}

static const char *
scratch(const struct fp_plist *p, size_t *len, const char *fmt, ...)
{
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(NULL, 0, fmt, ap);
	va_end(ap);
	p->scratch->len = 0;
	if (n < 0 || fp_buf_reserve(p->scratch, (size_t)n + 1) != 0)
		return NULL;
	va_start(ap, fmt);
	vsnprintf((char *)p->scratch->p, (size_t)n + 1, fmt, ap);
	va_end(ap);
	*len = (size_t)n;
	return (const char *)p->scratch->p;
}

static const char *const wdays[] = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
static const char *const months[] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct",
	"Nov", "Dec" };

const char *
fp_plist_lookup(const struct fp_plist *p, const char *keypath, size_t *len, int *why)
{
	const char *k = strip(keypath);
	const struct node *n = walk(p->root, k, k + strlen(k));
	struct tm6 t;

	if (n == NULL) {
		*why = FP_PLIST_MISSING;
		return NULL;
	}
	*why = 0;
	switch (n->type) {
	case P_STRING:
	case P_DATA:
		*len = n->v.len;
		return n->v.s;
	case P_INTEGER:
		return scratch(p, len, "%lld", s64(n->u));
	case P_REAL:
		if (n->r != n->r)
			return scratch(p, len, "nan");
		if (n->r > DBL_MAX || n->r < -DBL_MAX)
			return scratch(p, len, "%s", n->r > 0 ? "inf" : "-inf");
		return scratch(p, len, "%f", n->r);
	case P_BOOL:
		return scratch(p, len, "%s", n->u ? "true" : "false");
	case P_DATE:
		date_split(n->r, &t);
		return scratch(p, len, "%s %s %02d %02d:%02d:%02d UTC %lld", wdays[t.wday], months[t.mon - 1], t.day,
		    t.hour, t.min, t.sec, t.year);
	default:
		*why = FP_PLIST_NOT_SCALAR;
		return NULL;
	}
}

int
fp_plist_kind(const struct fp_plist *p, const char *keypath)
{
	const char *k = strip(keypath);
	const struct node *n = walk(p->root, k, k + strlen(k));

	if (n == NULL)
		return 0;
	if (n->type == P_STRING)
		return FP_PLIST_IS_STRING;
	return n->type == P_INTEGER ? FP_PLIST_IS_INTEGER : FP_PLIST_IS_OTHER;
}

const char *
fp_plist_get(const struct fp_plist *p, const char *keypath)
{
	size_t len;
	int why;

	return fp_plist_lookup(p, keypath, &len, &why);
}

int
fp_plist_set(struct fp_plist *p, const char *keypath, const char *type, const char *value)
{
	struct ctx c;
	const char *k = strip(keypath), *last;
	struct node *parent, *n, *old;
	struct str key = { 0 };
	size_t idx = 0, klen;

	c.name = p->name;
	c.failed = 0;
	c.nodes = 0;
	c.budget = 1;
	if (*k == '\0') {
		bad(&c, "cannot set the root");
		return FP_PLIST_MALFORMED;
	}
	if (!utf8_valid((const unsigned char *)keypath, strlen(keypath), 0)) {
		bad(&c, "keypath is not UTF-8");
		return FP_PLIST_MALFORMED;
	}
	if ((n = node_new(&c, P_STRING)) == NULL)
		return FP_PLIST_MALFORMED;
	if (strcmp(type, "string") == 0) {
		if (!utf8_valid((const unsigned char *)value, strlen(value), 0)) {
			bad(&c, "value is not UTF-8");
		} else if (str_dup(value, strlen(value), &n->v) != 0) {
			bad(&c, "out of memory");
		}
	} else if (strcmp(type, "integer") == 0) {
		n->type = P_INTEGER;
		if (parse_int(value, &n->uns, &n->u) != 0)
			bad(&c, "not an integer: %s", value);
	} else if (strcmp(type, "real") == 0) {
		n->type = P_REAL;
		if (parse_real(value, &n->r) != 0)
			bad(&c, "not a real: %s", value);
	} else if (strcmp(type, "bool") == 0) {
		n->type = P_BOOL;
		if (strcmp(value, "true") != 0 && strcmp(value, "false") != 0)
			bad(&c, "not a bool (true or false): %s", value);
		n->u = value[0] == 't';
	} else {
		bad(&c, "unsupported type %s: use string, integer, real or bool", type);
	}
	if (c.failed) {
		node_free(n);
		return FP_PLIST_MALFORMED;
	}
	last = strrchr(k, ':');
	last = last == NULL ? k : last + 1;
	parent = walk(p->root, k, last > k ? last - 1 : k);
	klen = strlen(last);
	if (parent == NULL || (parent->type != P_DICT && parent->type != P_ARRAY)) {
		bad(&c, "%s: %s", keypath, parent == NULL ? "no such entry" : "parent is not a dict or array");
		node_free(n);
		return FP_PLIST_MISSING;
	}
	if ((old = child(parent, last, klen, NULL)) != NULL && old->type != n->type) {
		bad(&c, "%s is a %s, not a %s: set keeps an existing entry's type", keypath, type_names[old->type], type);
		node_free(n);
		return FP_PLIST_MALFORMED;
	}
	if (parent->type == P_DICT) {
		if (str_dup(last, klen, &key) != 0 || node_push(parent, &key, n) != 0) {
			free(key.s);
			node_free(n);
			bad(&c, "out of memory");
			return FP_PLIST_MALFORMED;
		}
		return 0;
	}
	if (child(parent, last, klen, &idx) != NULL) {
		node_free(parent->kid[idx]);
		parent->kid[idx] = n;
		return 0;
	}
	if (klen == 0 || klen > 18 || strspn(last, "0123456789") != klen || idx != parent->n) {
		bad(&c, "%s: no such entry", keypath);
		node_free(n);
		return FP_PLIST_MISSING;
	}
	if (node_push(parent, NULL, n) != 0) {
		node_free(n);
		bad(&c, "out of memory");
		return FP_PLIST_MALFORMED;
	}
	return 0;
}

struct w {
	struct fp_buf *b;
	int err;
};

static void
put(struct w *w, const void *s, size_t n)
{
	if (!w->err && fp_buf_append(w->b, s, n) != 0)
		w->err = 1;
}

static void
puts_w(struct w *w, const char *s)
{
	put(w, s, strlen(s));
}

static void
tabs(struct w *w, int n)
{
	while (n-- > 0)
		put(w, "\t", 1);
}

static void
esc(struct w *w, const struct str *s)
{
	size_t i, from = 0;
	const char *rep;

	for (i = 0; i < s->len; i++) {
		rep = s->s[i] == '&' ? "&amp;" : s->s[i] == '<' ? "&lt;" : s->s[i] == '>' ? "&gt;" : NULL;
		if (rep == NULL)
			continue;
		put(w, s->s + from, i - from);
		puts_w(w, rep);
		from = i + 1;
	}
	put(w, s->s + from, s->len - from);
}

static void
elem(struct w *w, int ind, const char *tag, const struct str *s)
{
	tabs(w, ind);
	put(w, "<", 1);
	puts_w(w, tag);
	put(w, ">", 1);
	esc(w, s);
	puts_w(w, "</");
	puts_w(w, tag);
	puts_w(w, ">\n");
}

static void
elemf(struct w *w, int ind, const char *tag, const char *fmt, ...)
{
	char buf[512];
	struct str s;
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(buf, sizeof buf, fmt, ap);
	va_end(ap);
	if (n < 0 || (size_t)n >= sizeof buf) {
		w->err = 1;
		return;
	}
	s.s = buf;
	s.len = (size_t)n;
	elem(w, ind, tag, &s);
}

static void
wdata(struct w *w, const struct str *d, int ind)
{
	static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	const unsigned char *p = (const unsigned char *)d->s;
	int li = ind > 8 ? 8 : ind;
	size_t i, pos = 0, max = (size_t)(76 - 8 * li);
	char buf[80];

	tabs(w, ind);
	puts_w(w, "<data>\n");
	for (i = 0; i < d->len; i++) {
		switch (i % 3) {
		case 0:
			buf[pos++] = tbl[p[i] >> 2];
			break;
		case 1:
			buf[pos++] = tbl[(p[i - 1] & 0x3) << 4 | p[i] >> 4];
			break;
		default:
			buf[pos++] = tbl[(p[i - 1] & 0xF) << 2 | p[i] >> 6];
			buf[pos++] = tbl[p[i] & 0x3F];
			break;
		}
		if (pos >= max) {
			tabs(w, li);
			put(w, buf, pos);
			put(w, "\n", 1);
			pos = 0;
		}
	}
	if (i % 3 == 1) {
		buf[pos++] = tbl[(p[i - 1] & 0x3) << 4];
		buf[pos++] = '=';
		buf[pos++] = '=';
	} else if (i % 3 == 2) {
		buf[pos++] = tbl[(p[i - 1] & 0xF) << 2];
		buf[pos++] = '=';
	}
	if (pos > 0) {
		tabs(w, li);
		put(w, buf, pos);
		put(w, "\n", 1);
	}
	tabs(w, ind);
	puts_w(w, "</data>\n");
}

static unsigned long
utf16_lead(unsigned long cp)
{
	return cp >= 0x10000 ? 0xD800 + ((cp - 0x10000) >> 10) : cp;
}

static int
keycmp(const void *a, const void *b)
{
	const struct str *x = *(const struct str *const *)a, *y = *(const struct str *const *)b;
	const unsigned char *p = (const unsigned char *)x->s, *pe = p + x->len;
	const unsigned char *q = (const unsigned char *)y->s, *qe = q + y->len;
	unsigned long c1, c2;

	while (p < pe && q < qe) {
		c1 = utf8_next(&p, pe);
		c2 = utf8_next(&q, qe);
		if (c1 != c2) {
			if (utf16_lead(c1) != utf16_lead(c2))
				return utf16_lead(c1) < utf16_lead(c2) ? -1 : 1;
			return c1 < c2 ? -1 : 1;
		}
	}
	return (p < pe) - (q < qe);
}

static void
wvalue(struct w *w, const struct node *n, int ind)
{
	const struct str **keys;
	struct tm6 t;
	size_t i;

	switch (n->type) {
	case P_STRING:
		elem(w, ind, "string", &n->v);
		break;
	case P_INTEGER:
		if (n->uns)
			elemf(w, ind, "integer", "%llu", n->u);
		else
			elemf(w, ind, "integer", "%lld", s64(n->u));
		break;
	case P_REAL:
		if (n->r != n->r)
			elemf(w, ind, "real", "nan");
		else if (n->r > DBL_MAX || n->r < -DBL_MAX)
			elemf(w, ind, "real", "%s", n->r > 0 ? "+infinity" : "-infinity");
		else if (n->r == 0)
			elemf(w, ind, "real", "0.0");
		else
			elemf(w, ind, "real", "%.17g", n->r);
		break;
	case P_BOOL:
		tabs(w, ind);
		puts_w(w, n->u ? "<true/>\n" : "<false/>\n");
		break;
	case P_DATE:
		date_split(n->r, &t);
		elemf(w, ind, "date", "%04lld-%02d-%02dT%02d:%02d:%02dZ", t.year, t.mon, t.day, t.hour, t.min, t.sec);
		break;
	case P_DATA:
		wdata(w, &n->v, ind);
		break;
	case P_ARRAY:
		tabs(w, ind);
		if (n->n == 0) {
			puts_w(w, "<array/>\n");
			break;
		}
		puts_w(w, "<array>\n");
		for (i = 0; i < n->n; i++)
			wvalue(w, n->kid[i], ind + 1);
		tabs(w, ind);
		puts_w(w, "</array>\n");
		break;
	case P_DICT:
		tabs(w, ind);
		if (n->n == 0) {
			puts_w(w, "<dict/>\n");
			break;
		}
		if ((keys = malloc(n->n * sizeof *keys)) == NULL) {
			w->err = 1;
			break;
		}
		for (i = 0; i < n->n; i++)
			keys[i] = &n->key[i];
		qsort(keys, n->n, sizeof *keys, keycmp);
		puts_w(w, "<dict>\n");
		for (i = 0; i < n->n; i++) {
			elem(w, ind + 1, "key", keys[i]);
			wvalue(w, n->kid[keys[i] - n->key], ind + 1);
		}
		free(keys);
		tabs(w, ind);
		puts_w(w, "</dict>\n");
		break;
	}
}

int
fp_plist_write_xml(const struct fp_plist *p, struct fp_buf *out)
{
	struct w w;
	size_t start = out->len;

	w.b = out;
	w.err = 0;
	puts_w(&w, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
	    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
	    "<plist version=\"1.0\">\n");
	wvalue(&w, p->root, 0);
	puts_w(&w, "</plist>\n");
	if (w.err) {
		out->len = start;
		return -1;
	}
	return 0;
}
