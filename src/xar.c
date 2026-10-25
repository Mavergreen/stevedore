#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64

#include "xar.h"

#include <limits.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#include <zlib.h>

#include "gz.h"
#include "tree.h"

#define NONE ((size_t)-1)
#define MAX_TOC (64UL * 1024 * 1024)
#define MAX_DEPTH 256
#define CHUNK 65536

static int
refuse(const char *reason, const char *what)
{
	fprintf(stderr, "stevedore: %s: %s\n", reason, what);
	return FP_REFUSED;
}

static int
oom(void)
{
	fputs("stevedore: out of memory\n", stderr);
	return -1;
}

static int
put(struct fp_buf *b, int depth, const char *fmt, ...)
{
	va_list ap;
	int n;

	if (fp_buf_reserve(b, (size_t)depth) != 0)
		return -1;
	memset(b->p + b->len, ' ', (size_t)depth);
	b->len += (size_t)depth;
	va_start(ap, fmt);
	n = vsnprintf(NULL, 0, fmt, ap);
	va_end(ap);
	if (n < 0 || fp_buf_reserve(b, (size_t)n + 1) != 0)
		return -1;
	va_start(ap, fmt);
	vsnprintf((char *)b->p + b->len, (size_t)n + 1, fmt, ap);
	va_end(ap);
	b->len += (size_t)n;
	return 0;
}

static int
put_escaped(struct fp_buf *b, const char *s, size_t n)
{
	size_t i;
	int rc = 0;

	for (i = 0; i < n && rc == 0; i++) {
		if (s[i] == '&')
			rc = fp_buf_append(b, "&amp;", 5);
		else if (s[i] == '<')
			rc = fp_buf_append(b, "&lt;", 4);
		else if (s[i] == '>')
			rc = fp_buf_append(b, "&gt;", 4);
		else
			rc = fp_buf_append(b, s + i, 1);
	}
	return rc;
}

static void
iso8601(long t, char out[32])
{
	long z = t / 86400 + 719468, s = t % 86400, era, doe, yoe, doy, mp, d, m, y;

	era = z / 146097;
	doe = z - era * 146097;
	yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
	doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
	mp = (5 * doy + 2) / 153;
	d = doy - (153 * mp + 2) / 5 + 1;
	m = mp < 10 ? mp + 3 : mp - 9;
	y = yoe + era * 400 + (m <= 2);
	snprintf(out, 32, "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld", y, m, d, s / 3600, s / 60 % 60, s % 60);
}

struct wnode {
	const char *name;
	size_t namelen, entry, child, last, next;
};

struct writer {
	const struct fp_xar_entry *e;
	struct wnode *node;
	size_t n;
	struct fp_buf toc, heap;
	char when[32];
	unsigned long id;
};

static int
safe_component(const char *s, size_t n)
{
	return n > 0 && !(n == 1 && s[0] == '.') && !(n == 2 && s[0] == '.' && s[1] == '.');
}

static int
printable_utf8(const char *str)
{
	const unsigned char *s = (const unsigned char *)str;
	unsigned long c, min;
	int more;

	while (*s != '\0') {
		if (*s < 0x20 || *s == 0x7f)
			return 0;
		if (*s < 0x80) {
			s++;
			continue;
		}
		if ((*s & 0xe0) == 0xc0) {
			c = *s & 0x1f;
			more = 1;
			min = 0x80;
		} else if ((*s & 0xf0) == 0xe0) {
			c = *s & 0x0f;
			more = 2;
			min = 0x800;
		} else if ((*s & 0xf8) == 0xf0) {
			c = *s & 0x07;
			more = 3;
			min = 0x10000;
		} else {
			return 0;
		}
		for (s++; more > 0; more--, s++) {
			if ((*s & 0xc0) != 0x80)
				return 0;
			c = c << 6 | (*s & 0x3f);
		}
		if (c < min || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff))
			return 0;
	}
	return 1;
}

static size_t
find_child(const struct writer *w, size_t parent, const char *name, size_t n)
{
	size_t c;

	for (c = w->node[parent].child; c != NONE; c = w->node[c].next)
		if (w->node[c].namelen == n && memcmp(w->node[c].name, name, n) == 0)
			return c;
	return NONE;
}

static size_t
add_child(struct writer *w, size_t parent, const char *name, size_t n, size_t entry)
{
	size_t i = w->n++;

	w->node[i].name = name;
	w->node[i].namelen = n;
	w->node[i].entry = entry;
	w->node[i].child = w->node[i].last = w->node[i].next = NONE;
	if (w->node[parent].child == NONE)
		w->node[parent].child = i;
	else
		w->node[w->node[parent].last].next = i;
	w->node[parent].last = i;
	return i;
}

static int
place(struct writer *w, size_t entry)
{
	const char *path = w->e[entry].path, *s = path, *slash;
	size_t at = 0, n, c;

	if (!printable_utf8(path))
		return refuse("name is not printable UTF-8", path);
	for (;;) {
		slash = strchr(s, '/');
		n = slash ? (size_t)(slash - s) : strlen(s);
		if (!safe_component(s, n))
			return refuse("unsafe name", path);
		c = find_child(w, at, s, n);
		if (slash == NULL) {
			if (c != NONE)
				return refuse(w->node[c].entry == NONE ? "both a file and a directory" : "duplicate name", path);
			add_child(w, at, s, n, entry);
			return 0;
		}
		if (c == NONE)
			c = add_child(w, at, s, n, NONE);
		else if (w->node[c].entry != NONE)
			return refuse("both a file and a directory", path);
		at = c;
		s = slash + 1;
	}
}

static int
put_owner(struct writer *w, int depth, unsigned mode)
{
	return put(&w->toc, depth, "<mode>%04o</mode>\n", mode)
	    || put(&w->toc, depth, "<uid>0</uid>\n")
	    || put(&w->toc, depth, "<user>root</user>\n")
	    || put(&w->toc, depth, "<gid>0</gid>\n")
	    || put(&w->toc, depth, "<group>wheel</group>\n")
	    || put(&w->toc, depth, "<atime>%sZ</atime>\n", w->when)
	    || put(&w->toc, depth, "<mtime>%sZ</mtime>\n", w->when)
	    || put(&w->toc, depth, "<ctime>%sZ</ctime>\n", w->when);
}

static int
put_data(struct writer *w, int depth, const struct fp_xar_entry *e)
{
	unsigned char sum[FP_SHA1_LEN];
	char archived[2 * FP_SHA1_LEN + 1], extracted[2 * FP_SHA1_LEN + 1];
	size_t start = w->heap.len;
	unsigned long long offset = start, length;

	if (e->enc == FP_ENC_ZLIB) {
		if (fp_zlib(e->data, e->len, &w->heap) != 0)
			return -1;
	} else if (fp_buf_append(&w->heap, e->data, e->len) != 0) {
		return -1;
	}
	length = w->heap.len - start;
	fp_sha1(w->heap.p + start, (size_t)length, sum);
	fp_sha1_hex(sum, archived);
	fp_sha1(e->data, e->len, sum);
	fp_sha1_hex(sum, extracted);
	if (put(&w->toc, depth, "<data>\n")
	    || put(&w->toc, depth + 1, "<archived-checksum style=\"sha1\">%s</archived-checksum>\n", archived)
	    || put(&w->toc, depth + 1, "<extracted-checksum style=\"sha1\">%s</extracted-checksum>\n", extracted))
		return -1;
	if (e->enc == FP_ENC_ZLIB) {
		if (put(&w->toc, depth + 1, "<encoding style=\"application/x-gzip\"/>\n")
		    || put(&w->toc, depth + 1, "<size>%llu</size>\n", (unsigned long long)e->len)
		    || put(&w->toc, depth + 1, "<offset>%llu</offset>\n", offset))
			return -1;
	} else if (put(&w->toc, depth + 1, "<size>%llu</size>\n", (unsigned long long)e->len)
	    || put(&w->toc, depth + 1, "<offset>%llu</offset>\n", offset)
	    || put(&w->toc, depth + 1, "<encoding style=\"application/octet-stream\"/>\n")) {
		return -1;
	}
	return put(&w->toc, depth + 1, "<length>%llu</length>\n", length)
	    || put(&w->toc, depth, "</data>\n");
}

static int
put_node(struct writer *w, size_t i, int depth)
{
	const struct wnode *nd = &w->node[i];
	size_t c;

	if (put(&w->toc, depth, "<file id=\"%lu\">\n", ++w->id)
	    || put(&w->toc, depth + 1, "<name>")
	    || put_escaped(&w->toc, nd->name, nd->namelen)
	    || put(&w->toc, 0, "</name>\n")
	    || put(&w->toc, depth + 1, "<type>%s</type>\n", nd->entry == NONE ? "directory" : "file")
	    || put_owner(w, depth + 1, nd->entry == NONE ? 0700 : 0644))
		return -1;
	if (nd->entry != NONE) {
		if (put_data(w, depth + 1, &w->e[nd->entry]) != 0)
			return -1;
	} else {
		for (c = nd->child; c != NONE; c = w->node[c].next)
			if (put_node(w, c, depth + 1) != 0)
				return -1;
	}
	return put(&w->toc, depth, "</file>\n");
}

static int
put_be(struct fp_buf *b, unsigned long long v, int bytes)
{
	unsigned char p[8];
	int i;

	for (i = 0; i < bytes; i++)
		p[i] = (unsigned char)(v >> (8 * (bytes - 1 - i)));
	return fp_buf_append(b, p, (size_t)bytes);
}

int
fp_xar_write(const struct fp_xar_entry *e, size_t n, long mtime, struct fp_buf *out)
{
	struct writer w;
	struct fp_buf z = { 0 };
	unsigned char sum[FP_SHA1_LEN];
	size_t i, c, start = out->len, cap = 1;
	int rc = -1;

	memset(&w, 0, sizeof w);
	memset(sum, 0, sizeof sum);
	w.e = e;
	for (i = 0; i < n; i++)
		cap += strlen(e[i].path) + 1;
	if ((w.node = malloc(cap * sizeof *w.node)) == NULL)
		return oom();
	w.node[0].child = w.node[0].last = w.node[0].next = NONE;
	w.node[0].entry = NONE;
	w.n = 1;
	for (i = 0; i < n; i++)
		if ((rc = place(&w, i)) != 0)
			goto done;
	rc = -1;
	iso8601(mtime, w.when);
	if (fp_buf_append(&w.heap, sum, sizeof sum) != 0
	    || put(&w.toc, 0, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<xar>\n")
	    || put(&w.toc, 1, "<toc>\n")
	    || put(&w.toc, 2, "<checksum style=\"sha1\">\n")
	    || put(&w.toc, 3, "<size>20</size>\n")
	    || put(&w.toc, 3, "<offset>0</offset>\n")
	    || put(&w.toc, 2, "</checksum>\n")
	    || put(&w.toc, 2, "<creation-time>%s</creation-time>\n", w.when))
		goto nomem;
	for (c = w.node[0].child; c != NONE; c = w.node[c].next)
		if (put_node(&w, c, 2) != 0)
			goto nomem;
	if (put(&w.toc, 1, "</toc>\n") || put(&w.toc, 0, "</xar>\n") || fp_zlib(w.toc.p, w.toc.len, &z) != 0)
		goto nomem;
	fp_sha1(z.p, z.len, w.heap.p);
	if (fp_buf_append(out, "xar!", 4) || put_be(out, 28, 2) || put_be(out, 1, 2)
	    || put_be(out, z.len, 8) || put_be(out, w.toc.len, 8) || put_be(out, 1, 4)
	    || fp_buf_append(out, z.p, z.len) || fp_buf_append(out, w.heap.p, w.heap.len))
		goto nomem;
	rc = 0;
	goto done;
nomem:
	out->len = start;
	rc = oom();
done:
	free(w.node);
	fp_buf_free(&w.toc);
	fp_buf_free(&w.heap);
	fp_buf_free(&z);
	return rc;
}

struct xnode {
	char *name, *style;
	int enctype;
	struct fp_buf text;
	size_t child, last, next;
};

#define ENC_TEXT 0
#define ENC_BASE64 1
#define ENC_UNKNOWN 2

struct dom {
	struct xnode *n;
	size_t len, cap;
};

static void
dom_free(struct dom *d)
{
	size_t i;

	for (i = 0; i < d->len; i++) {
		free(d->n[i].name);
		free(d->n[i].style);
		fp_buf_free(&d->n[i].text);
	}
	free(d->n);
}

static int
put_utf8(struct fp_buf *b, unsigned long c)
{
	unsigned char u[4];
	size_t n;

	if (c == 0 || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff))
		return -2;
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
unescape(struct fp_buf *b, const char *s, size_t n)
{
	static const char *const ent[] = { "amp;&", "lt;<", "gt;>", "quot;\"", "apos;'" };
	size_t i = 0, j, k, el;
	unsigned long c;
	char *end;
	int rc;

	while (i < n) {
		for (j = i; j < n && s[j] != '&'; j++)
			;
		if (fp_buf_append(b, s + i, j - i) != 0)
			return -1;
		if (j == n)
			return 0;
		i = j + 1;
		for (k = 0; k < 5; k++) {
			el = strlen(ent[k]) - 1;
			if (n - i >= el && memcmp(s + i, ent[k], el) == 0)
				break;
		}
		if (k < 5) {
			if (fp_buf_append(b, ent[k] + el, 1) != 0)
				return -1;
			i += el;
			continue;
		}
		if (i >= n || s[i] != '#')
			return -2;
		i++;
		if (i < n && s[i] == 'x') {
			i++;
			if (i >= n || strchr("0123456789abcdefABCDEF", s[i]) == NULL)
				return -2;
			c = strtoul(s + i, &end, 16);
		} else {
			if (i >= n || s[i] < '0' || s[i] > '9')
				return -2;
			c = strtoul(s + i, &end, 10);
		}
		if ((size_t)(end - s) >= n || *end != ';')
			return -2;
		i = (size_t)(end - s) + 1;
		if ((rc = put_utf8(b, c)) != 0)
			return rc;
	}
	return 0;
}

static int
is_space(char c)
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static int
is_namech(char c)
{
	return c != '\0' && !is_space(c) && c != '/' && c != '>' && c != '=' && c != '<';
}

static const char *
skip_past(const char *p, const char *end, const char *marker)
{
	size_t m = strlen(marker);

	for (; (size_t)(end - p) >= m; p++)
		if (memcmp(p, marker, m) == 0)
			return p + m;
	return NULL;
}

static int
parse(const char *p, size_t len, struct dom *d)
{
	const char *end = p + len, *q, *v;
	size_t stack[MAX_DEPTH], depth = 0, i, nl, al;
	struct xnode *grown;
	struct fp_buf val;
	char quote;
	int rc;

	memset(d, 0, sizeof *d);
	while (p < end) {
		if (*p != '<') {
			for (q = p; q < end && *q != '<'; q++)
				;
			if (depth > 0) {
				if ((rc = unescape(&d->n[stack[depth - 1]].text, p, (size_t)(q - p))) != 0)
					return rc;
			} else {
				for (; p < q; p++)
					if (!is_space(*p))
						return -2;
			}
			p = q;
			continue;
		}
		if (end - p >= 2 && p[1] == '?') {
			if ((p = skip_past(p, end, "?>")) == NULL)
				return -2;
			continue;
		}
		if (end - p >= 4 && memcmp(p, "<!--", 4) == 0) {
			if ((p = skip_past(p, end, "-->")) == NULL)
				return -2;
			continue;
		}
		if (end - p >= 2 && p[1] == '!')
			return -2;
		if (end - p >= 2 && p[1] == '/') {
			p += 2;
			for (q = p; q < end && is_namech(*q); q++)
				;
			if (depth == 0 || strlen(d->n[stack[depth - 1]].name) != (size_t)(q - p)
			    || memcmp(d->n[stack[depth - 1]].name, p, (size_t)(q - p)) != 0)
				return -2;
			while (q < end && is_space(*q))
				q++;
			if (q == end || *q != '>')
				return -2;
			depth--;
			p = q + 1;
			continue;
		}
		p++;
		for (q = p; q < end && is_namech(*q); q++)
			;
		nl = (size_t)(q - p);
		if (nl == 0 || (depth == 0 && d->len > 0) || depth == MAX_DEPTH)
			return -2;
		if (d->len == d->cap) {
			d->cap = d->cap ? d->cap * 2 : 64;
			if ((grown = realloc(d->n, d->cap * sizeof *grown)) == NULL)
				return -1;
			d->n = grown;
		}
		i = d->len++;
		memset(&d->n[i], 0, sizeof d->n[i]);
		d->n[i].child = d->n[i].last = d->n[i].next = NONE;
		if ((d->n[i].name = malloc(nl + 1)) == NULL)
			return -1;
		memcpy(d->n[i].name, p, nl);
		d->n[i].name[nl] = '\0';
		if (depth > 0) {
			if (d->n[stack[depth - 1]].child == NONE)
				d->n[stack[depth - 1]].child = i;
			else
				d->n[d->n[stack[depth - 1]].last].next = i;
			d->n[stack[depth - 1]].last = i;
		}
		p = q;
		for (;;) {
			while (p < end && is_space(*p))
				p++;
			if (p == end)
				return -2;
			if (*p == '>') {
				stack[depth++] = i;
				p++;
				break;
			}
			if (*p == '/') {
				if (end - p < 2 || p[1] != '>')
					return -2;
				p += 2;
				break;
			}
			for (q = p; q < end && is_namech(*q); q++)
				;
			al = (size_t)(q - p);
			v = q;
			while (v < end && is_space(*v))
				v++;
			if (al == 0 || v == end || *v != '=')
				return -2;
			v++;
			while (v < end && is_space(*v))
				v++;
			if (v == end || (*v != '"' && *v != '\''))
				return -2;
			quote = *v++;
			for (q = v; q < end && *q != quote; q++)
				;
			if (q == end)
				return -2;
			if (al == 7 && memcmp(p, "enctype", 7) == 0)
				d->n[i].enctype = q - v == 6 && memcmp(v, "base64", 6) == 0 ? ENC_BASE64 : ENC_UNKNOWN;
			if (al == 5 && memcmp(p, "style", 5) == 0) {
				memset(&val, 0, sizeof val);
				if ((rc = unescape(&val, v, (size_t)(q - v))) != 0 || fp_buf_append(&val, "", 1) != 0) {
					fp_buf_free(&val);
					return rc ? rc : -1;
				}
				free(d->n[i].style);
				d->n[i].style = (char *)val.p;
			}
			p = q + 1;
		}
	}
	return depth == 0 && d->len > 0 ? 0 : -2;
}

static const char *
text_of(struct xnode *n)
{
	if (fp_buf_append(&n->text, "", 1) != 0)
		return NULL;
	n->text.len--;
	return (const char *)n->text.p;
}

static int
number(struct xnode *n, unsigned long long *v, int base)
{
	const char *s = text_of(n), *e;
	unsigned long long r = 0, d;

	if (s == NULL)
		return -1;
	while (is_space(*s))
		s++;
	for (e = s; (*e >= '0' && *e <= '9'); e++) {
		d = (unsigned long long)(*e - '0');
		if ((unsigned)d >= (unsigned)base || r > (ULLONG_MAX - d) / (unsigned)base)
			return -2;
		r = r * (unsigned)base + d;
	}
	if (e == s)
		return -2;
	while (is_space(*e))
		e++;
	if (*e != '\0')
		return -2;
	*v = r;
	return 0;
}

static int
trimmed_is(struct xnode *n, const char *want)
{
	const char *s = text_of(n);
	size_t l;

	if (s == NULL)
		return 0;
	while (is_space(*s))
		s++;
	l = strlen(s);
	while (l > 0 && is_space(s[l - 1]))
		l--;
	return l == strlen(want) && memcmp(s, want, l) == 0;
}

static int
hex_sum(struct xnode *n, unsigned char out[FP_SHA1_LEN])
{
	const char *s = text_of(n);
	int i, hi, lo;

	if (s == NULL)
		return -1;
	if (n->style == NULL || strcmp(n->style, "sha1") != 0)
		return -2;
	while (is_space(*s))
		s++;
	for (i = 0; i < 2 * FP_SHA1_LEN; i++)
		if (strchr("0123456789abcdefABCDEF", s[i]) == NULL || s[i] == '\0')
			return -2;
	for (i = 0; i < FP_SHA1_LEN; i++) {
		hi = s[2 * i] <= '9' ? s[2 * i] - '0' : (s[2 * i] | 0x20) - 'a' + 10;
		lo = s[2 * i + 1] <= '9' ? s[2 * i + 1] - '0' : (s[2 * i + 1] | 0x20) - 'a' + 10;
		out[i] = (unsigned char)(hi << 4 | lo);
	}
	for (s += 2 * FP_SHA1_LEN; is_space(*s); s++)
		;
	return *s == '\0' ? 0 : -2;
}

static int
unbase64(struct fp_buf *b)
{
	static const char abc[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	unsigned long acc = 0;
	size_t i, o = 0;
	int bits = 0, pad = 0;
	const char *k;

	for (i = 0; i < b->len; i++) {
		if (is_space((char)b->p[i]))
			continue;
		if (b->p[i] == '=') {
			pad++;
			continue;
		}
		if (pad > 0 || b->p[i] == '\0' || (k = strchr(abc, b->p[i])) == NULL)
			return -2;
		acc = (acc << 6 | (unsigned long)(k - abc)) & 0xffffff;
		if ((bits += 6) >= 8) {
			bits -= 8;
			b->p[o++] = (unsigned char)(acc >> bits);
		}
	}
	if (pad > 2 || (acc & ((1UL << bits) - 1)) != 0)
		return -2;
	b->len = o;
	return 0;
}

static struct xnode *
child_named(struct dom *d, size_t parent, const char *name)
{
	size_t c;

	for (c = d->n[parent].child; c != NONE; c = d->n[c].next)
		if (strcmp(d->n[c].name, name) == 0)
			return &d->n[c];
	return NULL;
}

static int
only_child(struct dom *d, size_t parent, const char *name, struct xnode **k)
{
	size_t c;

	*k = NULL;
	for (c = d->n[parent].child; c != NONE; c = d->n[c].next) {
		if (strcmp(d->n[c].name, name) != 0)
			continue;
		if (*k != NULL)
			return -2;
		*k = &d->n[c];
	}
	return 0;
}

static int
data_number(struct dom *d, size_t di, const char *name, unsigned long long *v)
{
	struct xnode *k;
	int rc;

	if ((rc = only_child(d, di, name, &k)) != 0)
		return rc;
	return k == NULL ? -2 : number(k, v, 10);
}

static int
data_sum(struct dom *d, size_t di, const char *name, unsigned char out[FP_SHA1_LEN])
{
	struct xnode *k;
	int rc;

	if ((rc = only_child(d, di, name, &k)) != 0)
		return rc;
	return k == NULL ? -2 : hex_sum(k, out);
}

static int
parse_data(struct dom *d, size_t di, struct fp_xar_file *f)
{
	struct xnode *k;
	int rc;

	f->has_data = 1;
	if ((rc = only_child(d, di, "encoding", &k)) != 0)
		return rc;
	if (k == NULL || k->style == NULL)
		f->enc = FP_ENC_NONE;
	else if (strcmp(k->style, "application/octet-stream") == 0)
		f->enc = FP_ENC_NONE;
	else if (strcmp(k->style, "application/x-gzip") == 0)
		f->enc = FP_ENC_ZLIB;
	else
		return -3;
	if ((rc = data_number(d, di, "offset", &f->offset)) != 0 || (rc = data_number(d, di, "length", &f->length)) != 0
	    || (rc = data_number(d, di, "size", &f->size)) != 0
	    || (rc = data_sum(d, di, "archived-checksum", f->archived)) != 0
	    || (rc = data_sum(d, di, "extracted-checksum", f->extracted)) != 0)
		return rc;
	return 0;
}

static int
walk(struct dom *d, size_t fi, const char *parent, struct fp_xar *x, int depth)
{
	struct fp_xar_file *f, *grown;
	struct xnode *k;
	const char *name = NULL, *t, *self;
	size_t c, pl, nl;
	unsigned long long mode;
	int rc;

	if (depth == MAX_DEPTH)
		return -2;
	for (c = d->n[fi].child; c != NONE; c = d->n[c].next) {
		if (strcmp(d->n[c].name, "name") != 0)
			continue;
		if (d->n[c].enctype == ENC_UNKNOWN || (d->n[c].enctype == ENC_BASE64 && unbase64(&d->n[c].text) != 0))
			return -2;
		d->n[c].enctype = ENC_TEXT;
		if ((t = text_of(&d->n[c])) == NULL)
			return -1;
		if (strlen(t) != d->n[c].text.len)
			return -2;
		if (name != NULL && strcmp(name, t) != 0)
			return -2;
		name = t;
	}
	if (name == NULL)
		return -2;
	if (x->n == x->cap) {
		x->cap = x->cap ? x->cap * 2 : 16;
		if ((grown = realloc(x->file, x->cap * sizeof *grown)) == NULL)
			return -1;
		x->file = grown;
	}
	f = &x->file[x->n++];
	memset(f, 0, sizeof *f);
	pl = parent ? strlen(parent) : 0;
	nl = strlen(name);
	if ((f->path = malloc(pl + nl + 2)) == NULL)
		return -1;
	if (parent)
		memcpy(f->path, parent, pl), f->path[pl++] = '/';
	memcpy(f->path + pl, name, nl + 1);
	f->unsafe = strchr(name, '/') != NULL || !safe_component(name, nl);
	if ((rc = only_child(d, fi, "type", &k)) != 0)
		return rc;
	f->type = k == NULL || trimmed_is(k, "file") ? FP_XAR_FILE : trimmed_is(k, "directory") ? FP_XAR_DIR
	    : trimmed_is(k, "symlink") ? FP_XAR_SYMLINK : FP_XAR_OTHER;
	f->mode = f->type == FP_XAR_DIR ? 0755 : 0644;
	if ((rc = only_child(d, fi, "mode", &k)) != 0)
		return rc;
	if (k != NULL) {
		if ((rc = number(k, &mode, 8)) != 0)
			return rc;
		f->mode = (unsigned long)(mode & 0777);
	}
	if ((rc = only_child(d, fi, "data", &k)) != 0)
		return rc;
	if (f->type == FP_XAR_FILE && k != NULL && (rc = parse_data(d, (size_t)(k - d->n), f)) != 0)
		return rc;
	self = f->path;
	for (c = d->n[fi].child; c != NONE; c = d->n[c].next)
		if (strcmp(d->n[c].name, "file") == 0 && (rc = walk(d, c, self, x, depth + 1)) != 0)
			return rc;
	return 0;
}

static unsigned long long
be(const unsigned char *p, int n)
{
	unsigned long long v = 0;
	int i;

	for (i = 0; i < n; i++)
		v = v << 8 | p[i];
	return v;
}

static int
seek_to(FILE *f, unsigned long long at)
{
	return at > (unsigned long long)LLONG_MAX || fseeko(f, (off_t)at, SEEK_SET) != 0 ? -1 : 0;
}

static int
read_at(FILE *f, unsigned long long at, void *p, size_t n)
{
	if (seek_to(f, at) != 0)
		return -1;
	return fread(p, 1, n, f) == n ? 0 : -1;
}

static int
inflate_toc(const unsigned char *in, size_t n, struct fp_buf *out, size_t want)
{
	z_stream s;
	int zr;

	if (fp_buf_reserve(out, want + 1) != 0)
		return -1;
	memset(&s, 0, sizeof s);
	if (inflateInit(&s) != Z_OK)
		return -1;
	s.next_in = (unsigned char *)in;
	s.avail_in = (uInt)n;
	s.next_out = out->p;
	s.avail_out = (uInt)want + 1;
	zr = inflate(&s, Z_FINISH);
	out->len = want + 1 - s.avail_out;
	inflateEnd(&s);
	if (zr != Z_STREAM_END || out->len != want || s.avail_in != 0)
		return -2;
	out->p[out->len] = '\0';
	return 0;
}

static int
toc_refused(int rc, const char *path)
{
	if (rc == -1)
		return oom();
	if (rc == -3)
		return refuse("unsupported encoding in archive", path);
	return refuse("malformed xar TOC", path);
}

static int
verify_archived(struct fp_xar *x, struct fp_xar_file *f)
{
	unsigned char buf[CHUNK], sum[FP_SHA1_LEN];
	unsigned long long left = f->length;
	struct fp_sha1 s;
	size_t take;

	if (f->offset > x->heap_len || f->length > x->heap_len - f->offset)
		return refuse("data outside the archive", f->path);
	fp_sha1_init(&s);
	if (left > 0 && seek_to(x->f, x->heap + f->offset) != 0)
		return refuse("cannot read", f->path);
	while (left > 0) {
		take = left > CHUNK ? CHUNK : (size_t)left;
		if (fread(buf, 1, take, x->f) != take)
			return refuse("cannot read", f->path);
		fp_sha1_update(&s, buf, take);
		left -= take;
	}
	fp_sha1_final(&s, sum);
	return memcmp(sum, f->archived, FP_SHA1_LEN) == 0 ? 0 : refuse("checksum mismatch", f->path);
}

int
fp_xar_read(const char *path, struct fp_xar *x)
{
	unsigned char h[28], sum[FP_SHA1_LEN], stored[FP_SHA1_LEN];
	struct fp_buf z = { 0 };
	struct dom d;
	struct xnode *k;
	unsigned long long hsize, clen, ulen, fsize, off, sz;
	size_t c, i, toc_at;
	int rc;

	memset(x, 0, sizeof *x);
	memset(&d, 0, sizeof d);
	if ((x->f = fopen(path, "rb")) == NULL) {
		perror(path);
		return -1;
	}
	if (fseeko(x->f, 0, SEEK_END) != 0 || ftello(x->f) < 0) {
		perror(path);
		return -1;
	}
	fsize = (unsigned long long)ftello(x->f);
	if (read_at(x->f, 0, h, sizeof h) != 0 || memcmp(h, "xar!", 4) != 0
	    || (hsize = be(h + 4, 2)) < 28 || be(h + 6, 2) != 1)
		return refuse("not a xar archive", path);
	clen = be(h + 8, 8);
	ulen = be(h + 16, 8);
	if (be(h + 24, 4) != 1)
		return refuse("not a sha1 xar archive", path);
	if (hsize > fsize || clen > fsize - hsize || fsize - hsize - clen < FP_SHA1_LEN || ulen > MAX_TOC || clen > MAX_TOC)
		return refuse("not a xar archive", path);
	x->heap = hsize + clen;
	x->heap_len = fsize - x->heap;
	if (fp_buf_reserve(&z, (size_t)clen) != 0)
		return oom();
	if (read_at(x->f, hsize, z.p, (size_t)clen) != 0 || read_at(x->f, x->heap, stored, sizeof stored) != 0) {
		fp_buf_free(&z);
		return refuse("not a xar archive", path);
	}
	fp_sha1(z.p, (size_t)clen, sum);
	if (memcmp(sum, stored, sizeof sum) != 0) {
		fp_buf_free(&z);
		return refuse("checksum mismatch", "TOC");
	}
	rc = inflate_toc(z.p, (size_t)clen, &x->toc, (size_t)ulen);
	fp_buf_free(&z);
	if (rc != 0)
		return toc_refused(rc, path);
	if ((rc = parse((const char *)x->toc.p, x->toc.len, &d)) != 0)
		goto bad;
	rc = -2;
	if (strcmp(d.n[0].name, "xar") != 0 || (k = child_named(&d, 0, "toc")) == NULL)
		goto bad;
	toc_at = (size_t)(k - d.n);
	if ((k = child_named(&d, toc_at, "checksum")) == NULL || k->style == NULL || strcmp(k->style, "sha1") != 0)
		goto bad;
	c = (size_t)(k - d.n);
	if ((k = child_named(&d, c, "offset")) == NULL || number(k, &off, 10) != 0 || off != 0
	    || (k = child_named(&d, c, "size")) == NULL || number(k, &sz, 10) != 0 || sz != FP_SHA1_LEN)
		goto bad;
	for (c = d.n[toc_at].child; c != NONE; c = d.n[c].next)
		if (strcmp(d.n[c].name, "file") == 0 && (rc = walk(&d, c, NULL, x, 0)) != 0)
			goto bad;
	dom_free(&d);
	for (i = 0; i < x->n; i++)
		if (x->file[i].has_data && (rc = verify_archived(x, &x->file[i])) != 0)
			return rc;
	return 0;
bad:
	dom_free(&d);
	return toc_refused(rc, path);
}

int
fp_xar_check_safe(const struct fp_xar *x)
{
	size_t i, j;

	for (i = 0; i < x->n; i++) {
		if (x->file[i].unsafe)
			return refuse("unsafe name in archive", x->file[i].path);
		if (x->file[i].type == FP_XAR_SYMLINK)
			return refuse("symlink in archive", x->file[i].path);
		if (x->file[i].type == FP_XAR_OTHER)
			return refuse("unsupported file type in archive", x->file[i].path);
		for (j = 0; j < i; j++)
			if (strcmp(x->file[i].path, x->file[j].path) == 0)
				return refuse("duplicate name in archive", x->file[i].path);
	}
	return 0;
}

static int
emit(fp_xar_sink sink, void *ctx, const struct fp_xar_file *f, struct fp_sha1 *s, const unsigned char *p, size_t n,
    unsigned long long *total)
{
	if (n > f->size - *total)
		return refuse("data larger than its declared size", f->path);
	fp_sha1_update(s, p, n);
	*total += n;
	return n == 0 || sink(ctx, p, n) == 0 ? 0 : -1;
}

int
fp_xar_extract(struct fp_xar *x, size_t i, fp_xar_sink sink, void *ctx)
{
	struct fp_xar_file *f = &x->file[i];
	unsigned char in[CHUNK], o[CHUNK], sum[FP_SHA1_LEN];
	unsigned long long left = f->length, total = 0;
	struct fp_sha1 s;
	z_stream zs;
	size_t take;
	int zr = Z_OK, rc = 0;

	fp_sha1_init(&s);
	if (!f->has_data)
		goto check;
	memset(&zs, 0, sizeof zs);
	if (f->enc == FP_ENC_ZLIB && inflateInit2(&zs, MAX_WBITS + 32) != Z_OK)
		return oom();
	if (seek_to(x->f, x->heap + f->offset) != 0)
		rc = refuse("cannot read", f->path);
	while (rc == 0 && left > 0) {
		take = left > CHUNK ? CHUNK : (size_t)left;
		if (fread(in, 1, take, x->f) != take) {
			rc = refuse("cannot read", f->path);
			break;
		}
		left -= take;
		if (f->enc == FP_ENC_NONE) {
			rc = emit(sink, ctx, f, &s, in, take, &total);
			continue;
		}
		zs.next_in = in;
		zs.avail_in = (uInt)take;
		do {
			zs.next_out = o;
			zs.avail_out = CHUNK;
			zr = inflate(&zs, Z_NO_FLUSH);
			if (zr == Z_BUF_ERROR && zs.avail_in == 0) {
				zr = Z_OK;
				break;
			}
			if (zr != Z_OK && zr != Z_STREAM_END)
				rc = refuse("corrupt data in archive", f->path);
			else
				rc = emit(sink, ctx, f, &s, o, CHUNK - zs.avail_out, &total);
		} while (rc == 0 && zr != Z_STREAM_END && (zs.avail_in > 0 || zs.avail_out == 0));
		if (rc == 0 && zr == Z_STREAM_END && (zs.avail_in > 0 || left > 0))
			rc = refuse("corrupt data in archive", f->path);
	}
	if (f->enc == FP_ENC_ZLIB) {
		if (rc == 0 && zr != Z_STREAM_END)
			rc = refuse("corrupt data in archive", f->path);
		inflateEnd(&zs);
	}
	if (rc != 0)
		return rc;
check:
	fp_sha1_final(&s, sum);
	if (f->has_data && total != f->size)
		return refuse("data smaller than its declared size", f->path);
	if (f->has_data && memcmp(sum, f->extracted, FP_SHA1_LEN) != 0)
		return refuse("checksum mismatch", f->path);
	return 0;
}

void
fp_xar_free(struct fp_xar *x)
{
	size_t i;

	for (i = 0; i < x->n; i++)
		free(x->file[i].path);
	free(x->file);
	fp_buf_free(&x->toc);
	if (x->f != NULL)
		fclose(x->f);
	memset(x, 0, sizeof *x);
}
