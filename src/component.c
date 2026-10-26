#define _POSIX_C_SOURCE 200809L

#include "component.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "bom.h"
#include "buf.h"
#include "cli.h"
#include "cpio.h"
#include "gz.h"
#include "plist.h"
#include "tree.h"
#include "xar.h"

#define NOMEM (-2)
#define HOPS 32
#define HFS_DIRENT 34
#define NVER 4

static const char *const ver_keys[NVER] = {
	"CFBundleShortVersionString", "CFBundleVersion", "SourceVersion", "BuildVersion",
};

struct staged {
	struct fp_tree t;
	struct fp_buf cpio;
	size_t *at;
};

struct bundle {
	size_t entry;
	char *plist, *id, *ver[NVER];
	int top, strict;
};

struct args {
	const char *root, *id, *version, *location, *scripts, *out;
	long mtime;
	int nopayload;
};

struct found {
	struct bundle *b;
	size_t n;
	char *root_plist;
};

static int
oom(void)
{
	fputs("stevedore: out of memory\n", stderr);
	return -1;
}

static int
refuse(const char *what, const char *path)
{
	fprintf(stderr, "stevedore: %s: %s\n", path, what);
	return 2;
}

static int
str_add(struct fp_buf *b, const char *s, size_t n)
{
	if (fp_buf_reserve(b, n + 1) != 0)
		return -1;
	memcpy(b->p + b->len, s, n);
	b->len += n;
	b->p[b->len] = '\0';
	return 0;
}

static int
str_set(struct fp_buf *b, const char *s)
{
	b->len = 0;
	return str_add(b, s, strlen(s));
}

static const char *
str(const struct fp_buf *b)
{
	return (const char *)b->p;
}

static int
is_dir(const struct fp_tree *t, long k)
{
	return k >= 0 && (t->e[k].mode & 0170000) == 040000;
}

static int
is_file(const struct fp_tree *t, long k)
{
	return k >= 0 && (t->e[k].mode & 0170000) == 0100000;
}

static int
ends_with(const char *s, const char *suffix)
{
	size_t l = strlen(s), m = strlen(suffix);

	return l >= m && strcmp(s + l - m, suffix) == 0;
}

static long
find(const struct fp_tree *t, const char *p, size_t n)
{
	size_t lo = 0, hi = t->n, mid;
	int c;

	while (lo < hi) {
		mid = lo + (hi - lo) / 2;
		c = strncmp(t->e[mid].path, p, n);
		if (c == 0 && t->e[mid].path[n] != '\0')
			c = 1;
		if (c == 0)
			return (long)mid;
		if (c < 0)
			lo = mid + 1;
		else
			hi = mid;
	}
	return -1;
}

static long
child(const struct fp_tree *t, struct fp_buf *dir, const char *name, size_t n)
{
	size_t dl = dir->len;
	long k;

	if (str_add(dir, "/", 1) || str_add(dir, name, n))
		return NOMEM;
	k = find(t, str(dir), dir->len);
	dir->len = dl;
	dir->p[dl] = '\0';
	return k;
}

static long
resolve(const struct fp_tree *t, const char *dir, const char *rel, struct fp_buf *cur)
{
	struct fp_buf rest = { 0 }, next = { 0 }, swap;
	const char *c, *e, *s;
	size_t n;
	long k;
	int hops = 0;

	if (str_set(cur, dir) || str_set(&rest, rel)) {
		k = NOMEM;
		goto out;
	}
	k = find(t, str(cur), cur->len);
	c = str(&rest);
	while (k >= 0 && *c != '\0') {
		e = strchr(c, '/');
		n = e != NULL ? (size_t)(e - c) : strlen(c);
		if (n == 2 && c[0] == '.' && c[1] == '.') {
			if ((s = strrchr(str(cur), '/')) == NULL) {
				k = -1;
				break;
			}
			cur->len = (size_t)(s - str(cur));
			cur->p[cur->len] = '\0';
			k = find(t, str(cur), cur->len);
		} else if (n > 0 && !(n == 1 && c[0] == '.')) {
			if ((k = child(t, cur, c, n)) < 0)
				break;
			if ((t->e[k].mode & 0170000) == 0120000) {
				if (++hops > HOPS || t->e[k].link_target[0] == '/') {
					k = -1;
					break;
				}
				if (str_set(&next, t->e[k].link_target)
				    || (e != NULL && (str_add(&next, "/", 1) || str_add(&next, e + 1, strlen(e + 1))))) {
					k = NOMEM;
					break;
				}
				swap = rest;
				rest = next;
				next = swap;
				c = str(&rest);
				k = find(t, str(cur), cur->len);
				continue;
			}
			if (e != NULL && !is_dir(t, k)) {
				k = -1;
				break;
			}
			if (str_add(cur, "/", 1) || str_add(cur, c, n)) {
				k = NOMEM;
				break;
			}
		}
		c = e != NULL ? e + 1 : c + n;
	}
out:
	fp_buf_free(&rest);
	fp_buf_free(&next);
	return k;
}

static long
file_in(const struct fp_tree *t, const char *dir, const char *sub, const char *name, struct fp_buf *real)
{
	struct fp_buf rel = { 0 };
	long k;

	if ((*sub != '\0' && (str_set(&rel, sub) || str_add(&rel, "/", 1)))
	    || str_add(&rel, name, strlen(name))) {
		fp_buf_free(&rel);
		return NOMEM;
	}
	k = resolve(t, dir, str(&rel), real);
	fp_buf_free(&rel);
	return k == NOMEM || is_file(t, k) ? k : -1;
}

static int
info_plist(const struct fp_tree *t, const char *dir, struct fp_buf *real, long *info, long *version)
{
	static const char *const framework[] = { "Resources", "Contents", "Support Files" };
	static const char *const other[] = { "Contents", "Resources", "Support Files" };
	const char *const *order = ends_with(dir, ".framework") ? framework : other;
	const char *sub = "";
	struct fp_buf tmp = { 0 };
	long k;
	int i;

	*version = -1;
	for (i = 0; i < 3 && *sub == '\0'; i++) {
		if ((k = resolve(t, dir, order[i], &tmp)) == NOMEM)
			goto nomem;
		if (is_dir(t, k))
			sub = order[i];
	}
	if ((*info = file_in(t, dir, sub, "Info-macos.plist", real)) == NOMEM
	    || (*info < 0 && (*info = file_in(t, dir, sub, "Info.plist", real)) == NOMEM)
	    || (*info >= 0 && (*version = file_in(t, dir, sub, "version.plist", &tmp)) == NOMEM))
		goto nomem;
	fp_buf_free(&tmp);
	return 0;
nomem:
	fp_buf_free(&tmp);
	return oom();
}

static int
parse(const struct staged *s, long k, struct fp_plist **p)
{
	const struct fp_entry *e = &s->t.e[k];

	return fp_plist_parse(s->cpio.p + s->at[k], (size_t)e->size, e->path, p) != 0 ? 2 : 0;
}

static int
value(const struct fp_plist *p, const char *key, const char *where, char **out)
{
	const char *v;
	size_t len;
	int why, kind = fp_plist_kind(p, key);

	*out = NULL;
	if (kind == 0)
		return 0;
	if (kind == FP_PLIST_IS_OTHER || (kind == FP_PLIST_IS_INTEGER && strcmp(key, "CFBundleIdentifier") == 0)) {
		fprintf(stderr, "stevedore: %s: %s is %s\n", where, key,
		    strcmp(key, "CFBundleIdentifier") == 0 ? "not a string" : "neither a string nor an integer");
		return 2;
	}
	if ((v = fp_plist_lookup(p, key, &len, &why)) == NULL)
		return oom();
	if (memchr(v, '\0', len) != NULL) {
		fprintf(stderr, "stevedore: %s: %s holds a NUL\n", where, key);
		return 2;
	}
	if ((*out = malloc(len + 1)) == NULL)
		return oom();
	memcpy(*out, v, len);
	(*out)[len] = '\0';
	return 0;
}

static void
bundle_free(struct bundle *b)
{
	int i;

	free(b->plist);
	free(b->id);
	for (i = 0; i < NVER; i++)
		free(b->ver[i]);
}

static void
found_free(struct found *f)
{
	size_t i;

	for (i = 0; i < f->n; i++)
		bundle_free(&f->b[i]);
	free(f->b);
	free(f->root_plist);
	memset(f, 0, sizeof *f);
}

static int
read_bundle(const struct staged *s, long info, long version, struct bundle *b)
{
	struct fp_plist *ip = NULL, *vp = NULL;
	int rc, i;

	if ((rc = parse(s, info, &ip)) != 0)
		return rc;
	if ((rc = value(ip, "CFBundleIdentifier", s->t.e[info].path, &b->id)) != 0 || b->id == NULL)
		goto out;
	if (version >= 0 && (rc = parse(s, version, &vp)) != 0)
		goto out;
	for (i = 0; i < NVER && rc == 0; i++) {
		if (vp != NULL && fp_plist_kind(vp, ver_keys[i]) != 0)
			rc = value(vp, ver_keys[i], s->t.e[version].path, &b->ver[i]);
		else
			rc = value(ip, ver_keys[i], s->t.e[info].path, &b->ver[i]);
	}
out:
	if (ip != NULL)
		fp_plist_free(ip);
	if (vp != NULL)
		fp_plist_free(vp);
	return rc;
}

static long
nearest(const struct fp_tree *t, const long *bundle_at, const char *path)
{
	size_t n = strlen(path);
	long k;

	for (;;) {
		while (n > 0 && path[n - 1] != '/')
			n--;
		if (n <= 2)
			return -1;
		n--;
		if ((k = find(t, path, n)) >= 0 && bundle_at[k] >= 0)
			return bundle_at[k];
	}
}

static int
discover(const struct staged *s, struct found *f)
{
	const struct fp_tree *t = &s->t;
	struct fp_buf real = { 0 };
	struct bundle b, *grown;
	long *bundle_at = malloc(t->n * sizeof *bundle_at), info, version, up;
	const char *against;
	size_t i, cap = 0;
	int rc = 0;

	memset(f, 0, sizeof *f);
	if (bundle_at == NULL)
		return oom();
	for (i = 0; i < t->n; i++)
		bundle_at[i] = -1;
	for (i = 0; i < t->n && rc == 0; i++) {
		if (!is_dir(t, (long)i))
			continue;
		if ((rc = info_plist(t, t->e[i].path, &real, &info, &version)) != 0 || info < 0)
			continue;
		if (i == 0) {
			if ((f->root_plist = malloc(real.len + 1)) == NULL)
				rc = oom();
			else
				memcpy(f->root_plist, real.p, real.len + 1);
			continue;
		}
		/* a directory whose Info.plist resolves to its nearest enclosing bundle's is that bundle */
		up = nearest(t, bundle_at, t->e[i].path);
		against = up >= 0 ? f->b[up].plist : f->root_plist;
		if (against != NULL && strcmp(against, str(&real)) == 0)
			continue;
		memset(&b, 0, sizeof b);
		if ((rc = read_bundle(s, info, version, &b)) != 0 || b.id == NULL) {
			bundle_free(&b);
			continue;
		}
		b.entry = i;
		b.top = up < 0;
		b.strict = ends_with(t->e[i].path, ".app");
		if ((b.plist = malloc(real.len + 1)) == NULL) {
			bundle_free(&b);
			rc = oom();
			continue;
		}
		memcpy(b.plist, real.p, real.len + 1);
		if (f->n == cap) {
			cap = cap ? cap * 2 : 8;
			if ((grown = realloc(f->b, cap * sizeof *grown)) == NULL) {
				bundle_free(&b);
				rc = oom();
				continue;
			}
			f->b = grown;
		}
		bundle_at[i] = (long)f->n;
		f->b[f->n++] = b;
	}
	free(bundle_at);
	fp_buf_free(&real);
	if (rc != 0)
		found_free(f);
	return rc;
}

static int
esc(struct fp_buf *o, const char *s, const char *what)
{
	const char *r;

	for (; *s != '\0'; s++) {
		if ((unsigned char)*s < 0x20 || *s == 0x7F) {
			fprintf(stderr, "stevedore: a control character in %s\n", what);
			return 2;
		}
		r = *s == '&' ? "&amp;" : *s == '<' ? "&lt;" : *s == '"' ? "&quot;" : NULL;
		if (r != NULL ? str_add(o, r, strlen(r)) : str_add(o, s, 1))
			return oom();
	}
	return 0;
}

static int
attr(struct fp_buf *o, const char *name, const char *value, const char *what)
{
	int rc;

	if (str_add(o, " ", 1) || str_add(o, name, strlen(name)) || str_add(o, "=\"", 2))
		return oom();
	if ((rc = esc(o, value, what)) != 0)
		return rc;
	return str_add(o, "\"", 1) ? oom() : 0;
}

static int
put(struct fp_buf *o, const char *s)
{
	return str_add(o, s, strlen(s)) ? oom() : 0;
}

static int
group(struct fp_buf *o, const struct staged *s, const struct found *f, const char *element, int strict)
{
	size_t i, n = 0;
	int rc;

	for (i = 0; i < f->n; i++)
		n += strict ? f->b[i].strict : f->b[i].top;
	if ((rc = put(o, "    <")) != 0 || (rc = put(o, element)) != 0
	    || (rc = put(o, n ? ">\n" : "/>\n")) != 0 || n == 0)
		return rc;
	for (i = 0; i < f->n; i++)
		if ((strict ? f->b[i].strict : f->b[i].top)
		    && ((rc = put(o, "        <bundle")) != 0
		    || (rc = attr(o, "id", f->b[i].id, s->t.e[f->b[i].entry].path)) != 0 || (rc = put(o, "/>\n")) != 0))
			return rc;
	if ((rc = put(o, "    </")) != 0 || (rc = put(o, element)) != 0)
		return rc;
	return put(o, ">\n");
}


static int
decimal(struct fp_buf *o, const char *name, unsigned long long v)
{
	char digits[24];

	snprintf(digits, sizeof digits, "%llu", v);
	return attr(o, name, digits, name);
}

static int
payload_element(struct fp_buf *o, unsigned long long files, unsigned long long kbytes)
{
	int rc;

	if ((rc = put(o, "    <payload")) != 0 || (rc = decimal(o, "numberOfFiles", files)) != 0
	    || (rc = decimal(o, "installKBytes", kbytes)) != 0)
		return rc;
	return put(o, "/>\n");
}

static int
package_info(struct fp_buf *o, const struct args *a, const struct staged *s, const struct found *f,
    const struct staged *scripts)
{
	static const char *const script_names[] = { "preinstall", "postinstall" };
	static const char *const script_paths[] = { "./preinstall", "./postinstall" };
	unsigned long long blocks = 0, size;
	size_t i;
	int rc, j, any = 0;

	/* installKBytes as pkgbuild counts it on HFS+: every entry in 512-byte blocks, halved, with a
	   directory 34 bytes per entry plus two */
	for (i = 0; i < s->t.n; i++) {
		const struct fp_entry *e = &s->t.e[i];

		size = (e->mode & 0170000) == 040000 ? HFS_DIRENT * ((unsigned long long)e->nchild + 2) : e->size;
		blocks += (size + 511) / 512;
	}
	if ((rc = put(o, "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"no\"?>\n"
	    "<pkg-info overwrite-permissions=\"true\" relocatable=\"false\"")) != 0
	    || (rc = attr(o, "identifier", a->id, "--identifier")) != 0
	    || (rc = put(o, " postinstall-action=\"none\"")) != 0
	    || (rc = attr(o, "version", a->version, "--version")) != 0
	    || (rc = put(o, " format-version=\"2\" generator-version=\"stevedore-" STEVEDORE_VERSION "\"")) != 0
	    || (rc = attr(o, "install-location", a->location, "--install-location")) != 0
	    || (rc = put(o, " auth=\"root\">\n")) != 0)
		return rc;
	if (!a->nopayload && (rc = payload_element(o, s->t.n, blocks / 2)) != 0)
		return rc;
	for (i = 0; i < f->n; i++) {
		const struct bundle *b = &f->b[i];
		const char *where = s->t.e[b->entry].path;

		if ((rc = put(o, "    <bundle")) != 0 || (rc = attr(o, "path", where, where)) != 0
		    || (rc = attr(o, "id", b->id, where)) != 0)
			return rc;
		for (j = 0; j < NVER; j++)
			if (b->ver[j] != NULL && (rc = attr(o, ver_keys[j], b->ver[j], where)) != 0)
				return rc;
		if ((rc = put(o, "/>\n")) != 0)
			return rc;
	}
	if ((rc = put(o, "    <bundle-version/>\n")) != 0 || (rc = group(o, s, f, "upgrade-bundle", 0)) != 0
	    || (rc = put(o, "    <update-bundle/>\n    <atomic-update-bundle/>\n")) != 0
	    || (rc = group(o, s, f, "strict-identifier", 1)) != 0
	    || (rc = put(o, "    <relocate/>\n")) != 0)
		return rc;
	for (j = 0; scripts != NULL && j < 2 && rc == 0; j++) {
		if (!is_file(&scripts->t, find(&scripts->t, script_paths[j], strlen(script_paths[j]))))
			continue;
		if (!any++)
			rc = put(o, "    <scripts>\n");
		if (rc == 0 && ((rc = put(o, "        <")) != 0 || (rc = put(o, script_names[j])) != 0
		    || (rc = put(o, " file=\"")) != 0 || (rc = put(o, script_paths[j])) != 0
		    || (rc = put(o, "\" timeout=\"600\"/>\n")) != 0))
			return rc;
	}
	if (rc == 0 && any)
		rc = put(o, "    </scripts>\n");
	return rc != 0 ? rc : put(o, "</pkg-info>");
}

static int
usage(void)
{
	fputs("usage: " FP_COMPONENT_USAGE, stderr);
	return 2;
}

static int
parse_args(int argc, char **argv, struct args *a)
{
	static const char *const names[] = {
		"--root", "--identifier", "--version", "--install-location", "--mtime", "--scripts", "--out",
	};
	const char *v[7] = { NULL, NULL, NULL, NULL, NULL, NULL, NULL };
	int i, j;

	a->nopayload = 0;
	for (i = 2; i < argc; i += 2) {
		if (strcmp(argv[i], "--nopayload") == 0) {
			if (a->nopayload)
				return usage();
			a->nopayload = 1;
			i--;
			continue;
		}
		for (j = 0; j < 7 && strcmp(argv[i], names[j]) != 0; j++)
			;
		if (j == 7 || i + 1 == argc || v[j] != NULL)
			return usage();
		v[j] = argv[i + 1];
	}
	for (j = 0; j < 7; j++)
		if (j != 5 && (j == 0 ? a->nopayload != (v[0] == NULL) : v[j] == NULL || *v[j] == '\0'))
			return usage();
	if (v[0] != NULL && *v[0] == '\0')
		return usage();
	a->root = v[0];
	a->id = v[1];
	a->version = v[2];
	a->location = v[3];
	a->scripts = v[5];
	a->out = v[6];
	return fp_parse_mtime(v[4], &a->mtime);
}

static int
stage(const char *dir, long mtime, struct staged *s, int want_at)
{
	struct stat st;
	int rc;

	memset(s, 0, sizeof *s);
	if (stat(dir, &st) != 0)
		return refuse(strerror(errno), dir);
	if ((rc = fp_tree_scan(dir, &s->t)) != 0)
		return rc < 0 ? 1 : rc;
	if (want_at && (s->at = malloc(s->t.n * sizeof *s->at)) == NULL)
		rc = oom();
	else
		rc = fp_cpio_odc(&s->t, mtime, &s->cpio, s->at);
	return rc < 0 ? 1 : rc;
}

static void
staged_free(struct staged *s)
{
	fp_tree_free(&s->t);
	fp_buf_free(&s->cpio);
	free(s->at);
}

static void
member(struct fp_xar_entry *e, const char *path, const struct fp_buf *b, int enc)
{
	e->path = path;
	e->data = b->p;
	e->len = b->len;
	e->enc = enc;
}

int
fp_component(int argc, char **argv)
{
	struct args a;
	struct staged root, scripts;
	struct found f = { 0 };
	struct fp_buf bom = { 0 }, payload = { 0 }, sgz = { 0 }, info = { 0 }, pkg = { 0 };
	struct fp_xar_entry e[4];
	size_t n = 0;
	int rc;

	memset(&root, 0, sizeof root);
	memset(&scripts, 0, sizeof scripts);
	if ((rc = parse_args(argc, argv, &a)) != 0)
		return rc;
	if ((!a.nopayload && (rc = stage(a.root, a.mtime, &root, 1)) != 0)
	    || (a.scripts != NULL && (rc = stage(a.scripts, a.mtime, &scripts, 0)) != 0)
	    || (!a.nopayload && (rc = fp_bom(&root.t, a.mtime, root.cpio.p, root.at, &bom)) != 0)
	    || (rc = discover(&root, &f)) != 0
	    || (rc = package_info(&info, &a, &root, &f, a.scripts != NULL ? &scripts : NULL)) != 0)
		goto out;
	if ((!a.nopayload && fp_gzip(root.cpio.p, root.cpio.len, &payload) != 0)
	    || (a.scripts != NULL && fp_gzip(scripts.cpio.p, scripts.cpio.len, &sgz) != 0)) {
		fputs("stevedore: gzip failed\n", stderr);
		rc = 1;
		goto out;
	}
	if (!a.nopayload) {
		member(&e[n++], "Bom", &bom, FP_ENC_ZLIB);
		member(&e[n++], "Payload", &payload, FP_ENC_NONE);
	}
	if (a.scripts != NULL)
		member(&e[n++], "Scripts", &sgz, FP_ENC_NONE);
	member(&e[n++], "PackageInfo", &info, FP_ENC_ZLIB);
	if ((rc = fp_xar_write(e, n, a.mtime, &pkg)) == 0)
		rc = fp_write_atomic(a.out, &pkg, -1);
out:
	staged_free(&root);
	staged_free(&scripts);
	found_free(&f);
	fp_buf_free(&bom);
	fp_buf_free(&payload);
	fp_buf_free(&sgz);
	fp_buf_free(&info);
	fp_buf_free(&pkg);
	return rc < 0 ? 1 : rc;
}
