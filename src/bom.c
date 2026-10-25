#include "bom.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The BOMStore layout lsbom reads, with field values and B-tree shape as pkgbuild on 10.9 writes them. */

#define HEADER 512
#define NODE 4096
#define VNODE 128
#define NODE_CAP 510
#define SPLIT 256
#define FIRST_PATH_BLOCK 11
#define U32_MAX 0xFFFFFFFFULL

struct path {
	const struct fp_entry *e;
	unsigned long id, parent;
	const char *name;
};

struct node {
	unsigned long id;
	size_t first, count, last;
	int leaf;
};

struct bom {
	struct fp_buf *out;
	size_t start;
	unsigned long *addr, *len;
	unsigned long nblocks;
	const unsigned char *base;
	const size_t *data_at;
};

static int
refuse(const char *reason, const char *path)
{
	fprintf(stderr, "stevedore: %s: %s\n", reason, path);
	return FP_REFUSED;
}

static int
put(struct fp_buf *b, unsigned long long v, int bytes)
{
	unsigned char c[4];
	int i;

	for (i = bytes - 1; i >= 0; i--) {
		c[i] = (unsigned char)(v & 0xFF);
		v >>= 8;
	}
	return fp_buf_append(b, c, (size_t)bytes);
}

static void
patch32(unsigned char *p, unsigned long v)
{
	p[0] = (unsigned char)(v >> 24);
	p[1] = (unsigned char)(v >> 16);
	p[2] = (unsigned char)(v >> 8);
	p[3] = (unsigned char)v;
}

static unsigned long crc_table[256];

static void
crc_init(void)
{
	unsigned long c;
	int i, k;

	if (crc_table[1] != 0)
		return;
	for (i = 0; i < 256; i++) {
		c = (unsigned long)i << 24;
		for (k = 0; k < 8; k++)
			c = c & 0x80000000UL ? (c << 1) ^ 0x04C11DB7UL : c << 1;
		crc_table[i] = c & 0xFFFFFFFFUL;
	}
}

static unsigned long
crc_update(unsigned long crc, const unsigned char *p, size_t n)
{
	while (n-- > 0)
		crc = ((crc << 8) ^ crc_table[((crc >> 24) ^ *p++) & 0xFF]) & 0xFFFFFFFFUL;
	return crc;
}

static unsigned long
crc_finish(unsigned long crc, unsigned long long n)
{
	unsigned char c;

	for (; n != 0; n >>= 8) {
		c = (unsigned char)(n & 0xFF);
		crc = crc_update(crc, &c, 1);
	}
	return ~crc & 0xFFFFFFFFUL;
}

static int
cmp_key(const void *a, const void *b)
{
	const struct path *x = a, *y = b;

	if (x->parent != y->parent)
		return x->parent < y->parent ? -1 : 1;
	return strcmp(x->name, y->name);
}

static size_t
find_dir(const struct fp_tree *t, const char *p, size_t len)
{
	size_t lo = 0, hi = t->n, mid;
	int c;

	while (lo < hi) {
		mid = lo + (hi - lo) / 2;
		c = strncmp(t->e[mid].path, p, len);
		if (c == 0 && t->e[mid].path[len] != '\0')
			c = 1;
		if (c == 0)
			return mid;
		if (c < 0)
			lo = mid + 1;
		else
			hi = mid;
	}
	return t->n;
}

static size_t
groups(size_t m)
{
	return m <= NODE_CAP ? 1 : (m - NODE_CAP + SPLIT - 1) / SPLIT + 1;
}

static size_t
group_size(size_t m, size_t g, size_t i)
{
	return i + 1 < g ? SPLIT : m - SPLIT * (g - 1);
}

static void
begin(struct bom *b, unsigned long id)
{
	b->addr[id] = (unsigned long)(b->out->len - b->start);
}

static void
end(struct bom *b, unsigned long id)
{
	b->len[id] = (unsigned long)(b->out->len - b->start) - b->addr[id];
}

static int
zeros(struct fp_buf *o, size_t n)
{
	if (fp_buf_reserve(o, n) != 0)
		return -1;
	memset(o->p + o->len, 0, n);
	o->len += n;
	return 0;
}

static int
tree_block(struct bom *b, unsigned long id, unsigned long child, unsigned long bs, unsigned long n)
{
	struct fp_buf *o = b->out;

	begin(b, id);
	if (fp_buf_append(o, "tree", 4) || put(o, 1, 4) || put(o, child, 4) || put(o, bs, 4)
	    || put(o, n, 4) || put(o, 0, 1))
		return -1;
	end(b, id);
	return 0;
}

static int
empty_leaf(struct bom *b, unsigned long id, size_t size)
{
	begin(b, id);
	if (put(b->out, 1, 2) || zeros(b->out, size - 2))
		return -1;
	end(b, id);
	return 0;
}

static int
node_block(struct bom *b, const struct node *nodes, size_t j, size_t nleaves, const struct path *keys)
{
	const struct node *nd = &nodes[j];
	struct fp_buf *o = b->out;
	size_t used = 12 + 8 * nd->count, i;
	unsigned long fwd = 0, back = 0, k;

	if (nd->leaf) {
		fwd = j + 1 < nleaves ? nodes[j + 1].id : 0;
		back = j > 0 ? nodes[j - 1].id : 0;
	}
	begin(b, nd->id);
	if (put(o, (unsigned long long)nd->leaf, 2) || put(o, nd->leaf ? nd->count : nd->count - 1, 2)
	    || put(o, fwd, 4) || put(o, back, 4))
		return -1;
	for (i = 0; i < nd->count; i++) {
		if (nd->leaf) {
			k = keys[nd->first + i].id;
			if (put(o, FIRST_PATH_BLOCK + 3 * (k - 1) + 2, 4)
			    || put(o, FIRST_PATH_BLOCK + 3 * (k - 1) + 1, 4))
				return -1;
		} else {
			const struct node *c = &nodes[nd->first + i];

			k = keys[c->last].id;
			if (put(o, c->id, 4)
			    || put(o, i + 1 < nd->count ? FIRST_PATH_BLOCK + 3 * (k - 1) + 1 : 0, 4))
				return -1;
		}
	}
	if (zeros(o, NODE - used))
		return -1;
	end(b, nd->id);
	return 0;
}

static int
path_blocks(struct bom *b, const struct path *p, unsigned long blk, long mtime, unsigned long crc)
{
	const struct fp_entry *e = p->e;
	struct fp_buf *o = b->out;
	unsigned long type = e->mode & 0170000;
	int dir = type == 040000, link = type == 0120000;
	size_t tl = link ? strlen(e->link_target) + 1 : 0;

	begin(b, blk);
	if (put(o, dir ? 2 : link ? 3 : 1, 1) || put(o, 1, 1) || put(o, 0x000f, 2)
	    || put(o, e->mode & 0xFFFF, 2) || put(o, 0, 4) || put(o, 0, 4)
	    || put(o, (unsigned long long)mtime, 4) || put(o, dir ? 0 : e->size, 4) || put(o, 1, 1)
	    || put(o, dir ? 0 : crc, 4) || put(o, tl, 4)
	    || (link && fp_buf_append(o, e->link_target, tl))
	    || zeros(o, dir ? 0 : link ? 8 : 4))
		return -1;
	end(b, blk);
	begin(b, blk + 1);
	if (put(o, p->parent, 4) || fp_buf_append(o, p->name, strlen(p->name) + 1))
		return -1;
	end(b, blk + 1);
	begin(b, blk + 2);
	if (put(o, p->id, 4) || put(o, blk, 4))
		return -1;
	end(b, blk + 2);
	return 0;
}

static int
validate(const struct fp_tree *t, long mtime, unsigned long long *total)
{
	unsigned long long sum = 0;
	size_t i;
	char num[32];

	if (mtime < 0 || (unsigned long long)mtime > U32_MAX) {
		snprintf(num, sizeof num, "%ld", mtime);
		return refuse("mtime out of range", num);
	}
	if (t->n == 0 || t->n > 0x10000000UL)
		return refuse("too many entries", ".");
	for (i = 0; i < t->n; i++) {
		const struct fp_entry *e = &t->e[i];

		if ((e->mode & 0170000) == 040000)
			continue;
		if (e->size > U32_MAX)
			return refuse("file too large", e->path);
		sum += e->size;
		if (sum > U32_MAX)
			return refuse("payload too large", e->path);
	}
	*total = sum;
	return 0;
}

static int
plan(const struct fp_tree *t, struct path **keys_out, struct node **nodes_out, size_t *nnodes,
    size_t *nleaves)
{
	size_t *dfs = fp_tree_dfs(t);
	unsigned long *ids = malloc(t->n * sizeof *ids);
	struct path *keys = malloc(t->n * sizeof *keys);
	struct node *nodes = NULL;
	size_t i, j, m, g, lo, total = 0, level_start, pos;

	if (dfs == NULL || ids == NULL || keys == NULL)
		goto oom;
	for (i = 0; i < t->n; i++)
		ids[dfs[i]] = (unsigned long)i + 1;
	for (i = 0; i < t->n; i++) {
		const char *p = t->e[i].path, *slash = strrchr(p, '/');

		keys[i].e = &t->e[i];
		keys[i].id = ids[i];
		if (slash == NULL) {
			keys[i].parent = 0;
			keys[i].name = p;
		} else {
			j = find_dir(t, p, (size_t)(slash - p));
			if (j == t->n) {
				fprintf(stderr, "stevedore: no parent directory in the tree: %s\n", p);
				goto fail;
			}
			keys[i].parent = ids[j];
			keys[i].name = slash + 1;
		}
	}
	qsort(keys, t->n, sizeof *keys, cmp_key);

	for (m = t->n; ; m = g) {
		g = groups(m);
		total += g;
		if (g == 1)
			break;
	}
	nodes = malloc(total * sizeof *nodes);
	if (nodes == NULL)
		goto oom;
	pos = 0;
	lo = 0;
	m = t->n;
	g = groups(m);
	for (i = 0; i < g; i++) {
		nodes[pos].leaf = 1;
		nodes[pos].first = lo;
		nodes[pos].count = group_size(m, g, i);
		lo += nodes[pos].count;
		nodes[pos].last = lo - 1;
		pos++;
	}
	*nleaves = g;
	level_start = 0;
	while (g > 1) {
		size_t child = level_start;

		level_start = pos;
		m = g;
		g = groups(m);
		for (i = 0; i < g; i++) {
			nodes[pos].leaf = 0;
			nodes[pos].first = child;
			nodes[pos].count = group_size(m, g, i);
			child += nodes[pos].count;
			nodes[pos].last = nodes[child - 1].last;
			pos++;
		}
	}
	for (i = 0; i < total; i++)
		nodes[i].id = i == 0 ? 3 : FIRST_PATH_BLOCK + 3 * (unsigned long)t->n + (unsigned long)i - 1;
	free(dfs);
	free(ids);
	*keys_out = keys;
	*nodes_out = nodes;
	*nnodes = total;
	return 0;
oom:
	fputs("stevedore: out of memory\n", stderr);
fail:
	free(dfs);
	free(ids);
	free(keys);
	free(nodes);
	return -1;
}

static const struct {
	unsigned long block;
	const char *name;
} vars[] = {
	{ 1, "BomInfo" }, { 2, "Paths" }, { 4, "HLIndex" }, { 6, "VIndex" }, { 9, "Size64" },
};

static int
emit(struct bom *b, const struct fp_tree *t, long mtime, unsigned long long total,
    const struct path *keys, const struct node *nodes, size_t nnodes, size_t nleaves)
{
	struct fp_buf *o = b->out;
	const struct path **byid = malloc(t->n * sizeof *byid);
	unsigned long crc, varsoff, varslen, indexoff, i;
	size_t k;
	int rc = -1;

	if (byid == NULL)
		goto oom;
	for (k = 0; k < t->n; k++)
		byid[keys[k].id - 1] = &keys[k];

	begin(b, 1);
	if (put(o, 1, 4) || put(o, t->n + 1, 4) || put(o, 1, 4) || put(o, 0, 4) || put(o, 0, 4)
	    || put(o, total, 4) || put(o, 0, 4))
		goto oom;
	end(b, 1);
	if (tree_block(b, 2, nodes[nnodes - 1].id, NODE, (unsigned long)t->n)
	    || node_block(b, nodes, 0, nleaves, keys)
	    || tree_block(b, 4, 5, NODE, 0) || empty_leaf(b, 5, NODE))
		goto oom;
	begin(b, 6);
	if (put(o, 1, 4) || put(o, 7, 4) || put(o, 0, 4) || put(o, 0, 1))
		goto oom;
	end(b, 6);
	if (tree_block(b, 7, 8, VNODE, 0) || empty_leaf(b, 8, VNODE)
	    || tree_block(b, 9, 10, NODE, 0) || empty_leaf(b, 10, NODE))
		goto oom;
	for (k = 0; k < t->n; k++) {
		const struct path *p = byid[k];
		unsigned long type = p->e->mode & 0170000;

		crc = 0;
		if (type == 0100000)
			crc = crc_finish(crc_update(0, b->base + b->data_at[p->e - t->e], (size_t)p->e->size),
			    p->e->size);
		if (type == 0120000)
			crc = crc_finish(crc_update(0, (const unsigned char *)p->e->link_target,
			    (size_t)p->e->size), p->e->size);
		if (path_blocks(b, p, FIRST_PATH_BLOCK + 3 * (unsigned long)k, mtime, crc))
			goto oom;
	}
	for (k = 1; k < nnodes; k++)
		if (node_block(b, nodes, k, nleaves, keys))
			goto oom;

	varsoff = (unsigned long)(o->len - b->start);
	if (put(o, sizeof vars / sizeof vars[0], 4))
		goto oom;
	for (k = 0; k < sizeof vars / sizeof vars[0]; k++)
		if (put(o, vars[k].block, 4) || put(o, strlen(vars[k].name), 1)
		    || fp_buf_append(o, vars[k].name, strlen(vars[k].name)))
			goto oom;
	varslen = (unsigned long)(o->len - b->start) - varsoff;
	indexoff = (unsigned long)(o->len - b->start);
	if (put(o, b->nblocks + 1, 4))
		goto oom;
	for (i = 0; i <= b->nblocks; i++)
		if (put(o, i ? b->addr[i] : 0, 4) || put(o, i ? b->len[i] : 0, 4))
			goto oom;
	if (put(o, 0, 4))
		goto oom;
	if (o->len - b->start > U32_MAX) {
		rc = refuse("Bom too large", ".");
		goto out;
	}
	memcpy(o->p + b->start, "BOMStore", 8);
	patch32(o->p + b->start + 8, 1);
	patch32(o->p + b->start + 12, b->nblocks);
	patch32(o->p + b->start + 16, indexoff);
	patch32(o->p + b->start + 20, (unsigned long)(o->len - b->start) - indexoff);
	patch32(o->p + b->start + 24, varsoff);
	patch32(o->p + b->start + 28, varslen);
	rc = 0;
	goto out;
oom:
	fputs("stevedore: out of memory\n", stderr);
out:
	free(byid);
	return rc;
}

int
fp_bom(const struct fp_tree *t, long mtime, const unsigned char *base, const size_t *data_at,
    struct fp_buf *out)
{
	struct bom b;
	struct path *keys = NULL;
	struct node *nodes = NULL;
	unsigned long long total;
	size_t nnodes, nleaves;
	int rc = validate(t, mtime, &total);

	if (rc != 0)
		return rc;
	crc_init();
	if (plan(t, &keys, &nodes, &nnodes, &nleaves) != 0)
		return -1;
	memset(&b, 0, sizeof b);
	b.out = out;
	b.base = base;
	b.data_at = data_at;
	b.start = out->len;
	b.nblocks = 10 + 3 * (unsigned long)t->n + (unsigned long)nnodes - 1;
	b.addr = calloc(b.nblocks + 1, sizeof *b.addr);
	b.len = calloc(b.nblocks + 1, sizeof *b.len);
	if (b.addr == NULL || b.len == NULL || zeros(out, HEADER) != 0) {
		fputs("stevedore: out of memory\n", stderr);
		rc = -1;
	} else {
		rc = emit(&b, t, mtime, total, keys, nodes, nnodes, nleaves);
	}
	if (rc != 0)
		out->len = b.start;
	free(b.addr);
	free(b.len);
	free(keys);
	free(nodes);
	return rc;
}
