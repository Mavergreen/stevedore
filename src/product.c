#define _POSIX_C_SOURCE 200809L

#include "product.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "buf.h"
#include "cli.h"
#include "xar.h"
#include "xml.h"

#define NMEMBER 4
#define NRES 5
#define MAXRES (NRES * 8)

static const char *const members[NMEMBER] = { "PackageInfo", "Scripts", "Payload", "Bom" };
static const char *const res_elements[NRES] = { "background", "welcome", "readme", "license", "conclusion" };

struct component {
	const char *path, *dir, *id, *version, *kbytes;
	struct fp_buf data[NMEMBER];
	int have[NMEMBER], enc[NMEMBER], toc[NMEMBER], ntoc, ordered;
	struct fp_xml_doc info;
};

struct resource {
	const char *file;
	struct fp_buf data;
};

struct args {
	const char *dist, *res, *out;
	const char **pkg;
	size_t npkg;
	long mtime;
};

struct product {
	struct component *c;
	size_t nc;
	struct component **order;
	size_t norder;
	struct resource res[MAXRES];
	size_t nres;
};

static int
oom(void)
{
	fputs("stevedore: out of memory\n", stderr);
	return -1;
}

static int
usage(void)
{
	fputs("usage: " FP_PRODUCT_USAGE, stderr);
	return 2;
}

static int
parse_args(int argc, char **argv, struct args *a)
{
	const char *mtime = NULL, **slot;
	int i;

	memset(a, 0, sizeof *a);
	if ((a->pkg = calloc((size_t)argc, sizeof *a->pkg)) == NULL)
		return oom();
	for (i = 2; i < argc; i += 2) {
		if (i + 1 == argc)
			return usage();
		if (strcmp(argv[i], "--package") == 0) {
			a->pkg[a->npkg++] = argv[i + 1];
			continue;
		}
		slot = strcmp(argv[i], "--distribution") == 0 ? &a->dist : strcmp(argv[i], "--resources") == 0 ? &a->res
		    : strcmp(argv[i], "--out") == 0 ? &a->out : strcmp(argv[i], "--mtime") == 0 ? &mtime : NULL;
		if (slot == NULL || *slot != NULL)
			return usage();
		*slot = argv[i + 1];
	}
	if (a->dist == NULL || a->out == NULL || mtime == NULL || a->npkg == 0)
		return usage();
	return fp_parse_mtime(mtime, &a->mtime);
}

static int
read_file(const char *path, struct fp_buf *b)
{
	FILE *f = fopen(path, "rb");
	int rc = 0;

	if (f == NULL) {
		fprintf(stderr, "stevedore: %s: %s\n", path, strerror(errno));
		return 2;
	}
	if (fp_read_all(f, b) != 0) {
		perror(path);
		rc = 1;
	}
	fclose(f);
	return rc;
}

static int
buf_sink(void *ctx, const unsigned char *p, size_t n)
{
	return fp_buf_append(ctx, p, n) == 0 ? 0 : oom();
}

static const struct fp_xml_node *
child_named(const struct fp_xml_node *e, const char *name, size_t *from)
{
	size_t i;

	for (i = from != NULL ? *from : 0; i < e->nchild; i++) {
		if (e->child[i]->kind == FP_XML_ELEMENT && strcmp(e->child[i]->name, name) == 0) {
			if (from != NULL)
				*from = i + 1;
			return e->child[i];
		}
	}
	return NULL;
}

static int
digits(const char *s)
{
	if (s == NULL || *s == '\0')
		return 0;
	for (; *s != '\0'; s++)
		if (*s < '0' || *s > '9')
			return 0;
	return 1;
}

static int
package_info(struct component *c)
{
	struct fp_buf name = { 0 };
	const struct fp_xml_node *root, *payload;
	int rc;

	if (fp_buf_append(&name, c->path, strlen(c->path)) || fp_buf_append(&name, "/PackageInfo", 13))
		return oom();
	rc = fp_xml_parse(c->data[0].p, c->data[0].len, (const char *)name.p, &c->info);
	if (rc == 0) {
		root = c->info.root;
		c->id = fp_xml_get(root, "identifier");
		c->version = fp_xml_get(root, "version");
		payload = child_named(root, "payload", NULL);
		c->kbytes = payload != NULL ? fp_xml_get(payload, "installKBytes") : c->have[2] ? NULL : "0";
		if (strcmp(root->name, "pkg-info") != 0 || c->id == NULL || *c->id == '\0' || c->version == NULL
		    || *c->version == '\0' || !digits(c->kbytes)) {
			fprintf(stderr, "stevedore: %s: not a pkg-info with an identifier, a version and a payload's installKBytes\n",
			    (const char *)name.p);
			rc = 2;
		}
	}
	fp_buf_free(&name);
	return rc;
}

static int
read_component(struct component *c)
{
	struct fp_xar x;
	const char *slash = strrchr(c->path, '/');
	size_t i, l;
	int k, rc;

	c->dir = slash != NULL ? slash + 1 : c->path;
	l = strlen(c->dir);
	if (l <= 4 || strcmp(c->dir + l - 4, ".pkg") != 0) {
		fprintf(stderr, "stevedore: %s: a component's file name must end in .pkg\n", c->path);
		return 2;
	}
	if ((rc = fp_xar_read(c->path, &x)) == 0)
		rc = fp_xar_check_safe(&x);
	for (i = 0; rc == 0 && i < x.n; i++) {
		for (k = 0; k < NMEMBER && strcmp(x.file[i].path, members[k]) != 0; k++)
			;
		if (k == NMEMBER || x.file[i].type != FP_XAR_FILE) {
			fprintf(stderr, "stevedore: %s: holds %s, which is not a component's Bom, Payload, Scripts or PackageInfo\n",
			    c->path, x.file[i].path);
			rc = 2;
			break;
		}
		c->have[k] = 1;
		c->toc[c->ntoc++] = k;
		c->enc[k] = x.file[i].enc;
		rc = fp_xar_extract(&x, i, buf_sink, &c->data[k]);
	}
	fp_xar_free(&x);
	if (rc == 0 && !(c->have[0] && c->have[2] == c->have[3])) {
		fprintf(stderr, "stevedore: %s: a component needs a PackageInfo, and a Payload and a Bom together or neither\n", c->path);
		rc = 2;
	}
	if (rc == 0)
		rc = package_info(c);
	return rc < 0 ? 1 : rc;
}

static struct component *
component_for(struct product *pr, const char *id)
{
	size_t i;

	for (i = 0; i < pr->nc; i++)
		if (strcmp(pr->c[i].id, id) == 0)
			return &pr->c[i];
	return NULL;
}

static int
known(struct product *pr, const struct fp_xml_node *ref, struct component **c)
{
	const char *id = fp_xml_get(ref, "id");

	if (id == NULL) {
		fputs("stevedore: the distribution has a pkg-ref without an id\n", stderr);
		return 2;
	}
	if ((*c = component_for(pr, id)) == NULL) {
		fprintf(stderr, "stevedore: the distribution's pkg-ref %s matches no --package component\n", id);
		return 2;
	}
	return 0;
}

static int
every_ref_known(struct product *pr, const struct fp_xml_node *e)
{
	struct component *c;
	size_t i;
	int rc;

	if (strcmp(e->name, "pkg-ref") == 0 && (rc = known(pr, e, &c)) != 0)
		return rc;
	for (i = 0; i < e->nchild; i++)
		if (e->child[i]->kind == FP_XML_ELEMENT && (rc = every_ref_known(pr, e->child[i])) != 0)
			return rc;
	return 0;
}

static int
outline(struct product *pr, const struct fp_xml_node *root, const struct fp_xml_node *e)
{
	const struct fp_xml_node *line, *choice, *ref;
	struct component *c;
	const char *want, *id;
	size_t at = 0, from, j;
	int rc;

	while ((line = child_named(e, "line", &at)) != NULL) {
		if ((want = fp_xml_get(line, "choice")) == NULL) {
			fputs("stevedore: the distribution's choices-outline has a line without a choice\n", stderr);
			return 2;
		}
		from = 0;
		while ((choice = child_named(root, "choice", &from)) != NULL
		    && ((id = fp_xml_get(choice, "id")) == NULL || strcmp(id, want) != 0))
			;
		if (choice == NULL) {
			fprintf(stderr, "stevedore: the distribution's choices-outline names choice %s, which no choice defines\n", want);
			return 2;
		}
		for (j = 0; (ref = child_named(choice, "pkg-ref", &j)) != NULL;) {
			if ((rc = known(pr, ref, &c)) != 0)
				return rc;
			if (!c->ordered) {
				c->ordered = 1;
				pr->order[pr->norder++] = c;
			}
		}
		if ((rc = outline(pr, root, line)) != 0)
			return rc;
	}
	return 0;
}

static int
fill(struct component *c, struct fp_xml_node *root)
{
	struct fp_xml_node *ref = NULL, *e;
	struct fp_buf hash = { 0 };
	const char *id, *text, *end;
	size_t i, n = 0, l;
	int rc;

	for (i = 0; i < root->nchild; i++) {
		e = root->child[i];
		if (e->kind != FP_XML_ELEMENT || strcmp(e->name, "pkg-ref") != 0 || (id = fp_xml_get(e, "id")) == NULL
		    || strcmp(id, c->id) != 0 || (text = fp_xml_text(e)) == NULL)
			continue;
		while (*text == ' ' || *text == '\t' || *text == '\n')
			text++;
		for (end = text + strlen(text); end > text && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\n'); end--)
			;
		if (end == text)
			continue;
		if (*text == '#')
			text++;
		l = strlen(c->dir);
		if ((size_t)(end - text) != l || memcmp(text, c->dir, l) != 0) {
			fprintf(stderr, "stevedore: the distribution's pkg-ref %s names %.*s, not %s\n", c->id, (int)(end - text), text, c->dir);
			return 2;
		}
		ref = e;
		n++;
	}
	if (n != 1) {
		fprintf(stderr, "stevedore: the distribution has %s pkg-ref naming the package for %s\n", n ? "more than one" : "no", c->id);
		return 2;
	}
	if (fp_buf_append(&hash, "#", 1) || fp_buf_append(&hash, c->dir, strlen(c->dir) + 1)) {
		fp_buf_free(&hash);
		return oom();
	}
	rc = fp_xml_set(ref, "version", c->version) || fp_xml_set(ref, "installKBytes", c->kbytes)
	    || fp_xml_set(ref, "updateKBytes", "0") || fp_xml_set_text(ref, (const char *)hash.p) ? 1 : 0;
	fp_buf_free(&hash);
	return rc;
}

static int
bundle_versions(struct component *c, struct fp_xml_node *root)
{
	const struct fp_xml_node *b;
	struct fp_xml_node *ref, *bv, *out;
	const char *id, *path;
	size_t at = 0, i;

	if ((ref = fp_xml_add(root, "pkg-ref")) == NULL || fp_xml_set(ref, "id", c->id)
	    || (bv = fp_xml_add(ref, "bundle-version")) == NULL)
		return 1;
	while ((b = child_named(c->info.root, "bundle", &at)) != NULL) {
		id = fp_xml_get(b, "id");
		path = fp_xml_get(b, "path");
		if (id == NULL || path == NULL) {
			fprintf(stderr, "stevedore: %s/PackageInfo: a bundle without an id or a path\n", c->path);
			return 2;
		}
		if (strncmp(path, "./", 2) == 0)
			path += 2;
		if ((out = fp_xml_add(bv, "bundle")) == NULL)
			return 1;
		for (i = 0; i < b->nattr; i++)
			if (strcmp(b->attr[i].name, "id") != 0 && strcmp(b->attr[i].name, "path") != 0
			    && fp_xml_set(out, b->attr[i].name, b->attr[i].value))
				return 1;
		if (fp_xml_set(out, "id", id) || fp_xml_set(out, "path", path))
			return 1;
	}
	return 0;
}

static int
only_in_lproj(const char *dir, const char *file)
{
	struct dirent *de;
	struct stat st;
	char *p;
	size_t l, pl;
	DIR *d;
	int found = 0;

	if ((d = opendir(dir)) == NULL)
		return 0;
	while (!found && (de = readdir(d)) != NULL) {
		l = strlen(de->d_name);
		if (l <= 6 || strcmp(de->d_name + l - 6, ".lproj") != 0)
			continue;
		pl = strlen(dir) + l + strlen(file) + 3;
		if ((p = malloc(pl)) == NULL)
			break;
		snprintf(p, pl, "%s/%s/%s", dir, de->d_name, file);
		found = stat(p, &st) == 0;
		free(p);
	}
	closedir(d);
	return found;
}

static int
resources(struct product *pr, const struct fp_xml_node *root, const char *dir)
{
	const struct fp_xml_node *e;
	struct stat st;
	const char *file;
	char *p;
	size_t at, i, pl;
	int k, rc, dup;

	for (k = 0; k < NRES; k++) {
		for (at = 0; (e = child_named(root, res_elements[k], &at)) != NULL;) {
			if ((file = fp_xml_get(e, "file")) == NULL)
				continue;
			if (*file == '\0' || strchr(file, '/') != NULL || strcmp(file, ".") == 0 || strcmp(file, "..") == 0) {
				fprintf(stderr, "stevedore: the distribution's %s file %s is not a plain file name\n", res_elements[k], file);
				return 2;
			}
			if (dir == NULL)
				continue;
			for (dup = 0, i = 0; i < pr->nres; i++)
				dup |= strcmp(pr->res[i].file, file) == 0;
			if (dup)
				continue;
			pl = strlen(dir) + strlen(file) + 2;
			if ((p = malloc(pl)) == NULL)
				return oom();
			snprintf(p, pl, "%s/%s", dir, file);
			rc = 0;
			if (stat(p, &st) != 0) {
				if (only_in_lproj(dir, file)) {
					fprintf(stderr, "stevedore: %s: %s is only in a .lproj, and stevedore reads the top of --resources only\n", dir, file);
					rc = 2;
				}
			} else if (!S_ISREG(st.st_mode)) {
				fprintf(stderr, "stevedore: %s: not a regular file\n", p);
				rc = 2;
			} else if (pr->nres == MAXRES) {
				fputs("stevedore: the distribution references too many resources\n", stderr);
				rc = 2;
			} else if ((rc = read_file(p, &pr->res[pr->nres].data)) == 0) {
				pr->res[pr->nres++].file = file;
			}
			free(p);
			if (rc != 0)
				return rc;
		}
	}
	return 0;
}

static int
distribution(struct product *pr, const struct args *a, struct fp_xml_doc *d)
{
	struct fp_buf raw = { 0 };
	const struct fp_xml_node *co;
	size_t i, at = 0;
	int rc;

	if ((rc = read_file(a->dist, &raw)) == 0)
		rc = fp_xml_parse(raw.p, raw.len, a->dist, d);
	fp_buf_free(&raw);
	if (rc != 0)
		return rc;
	if (strcmp(d->root->name, "installer-gui-script") != 0) {
		fprintf(stderr, "stevedore: %s: the root element is %s, not installer-gui-script\n", a->dist, d->root->name);
		return 2;
	}
	if ((rc = every_ref_known(pr, d->root)) != 0)
		return rc;
	while ((co = child_named(d->root, "choices-outline", &at)) != NULL)
		if ((rc = outline(pr, d->root, co)) != 0)
			return rc;
	for (i = 0; i < pr->nc; i++) {
		if (!pr->c[i].ordered) {
			fprintf(stderr, "stevedore: %s: component %s is not reached from the distribution's choices-outline\n",
			    pr->c[i].path, pr->c[i].id);
			return 2;
		}
	}
	for (i = 0; i < pr->norder; i++)
		if ((rc = fill(pr->order[i], d->root)) != 0)
			return rc;
	for (i = 0; i < pr->norder; i++)
		if ((rc = bundle_versions(pr->order[i], d->root)) != 0)
			return rc;
	return resources(pr, d->root, a->res);
}

static int
write_product(struct product *pr, const struct fp_buf *dist, const struct args *a)
{
	struct fp_xar_entry *e;
	struct fp_buf out = { 0 };
	char **names;
	size_t n = 0, cap = pr->norder * NMEMBER + pr->nres + 1, i, l;
	int k, m, rc = 0;

	e = calloc(cap, sizeof *e);
	names = calloc(cap, sizeof *names);
	if (e == NULL || names == NULL)
		rc = oom();
	for (i = 0; rc == 0 && i < pr->norder; i++) {
		for (m = pr->order[i]->ntoc; rc == 0 && m-- > 0;) {
			k = pr->order[i]->toc[m];
			l = strlen(pr->order[i]->dir) + strlen(members[k]) + 2;
			if ((names[n] = malloc(l)) == NULL) {
				rc = oom();
				break;
			}
			snprintf(names[n], l, "%s/%s", pr->order[i]->dir, members[k]);
			e[n].path = names[n];
			e[n].data = pr->order[i]->data[k].p;
			e[n].len = pr->order[i]->data[k].len;
			e[n++].enc = pr->order[i]->enc[k];
		}
	}
	for (i = 0; rc == 0 && i < pr->nres; i++) {
		l = strlen(pr->res[i].file) + 11;
		if ((names[n] = malloc(l)) == NULL) {
			rc = oom();
			break;
		}
		snprintf(names[n], l, "Resources/%s", pr->res[i].file);
		e[n].path = names[n];
		e[n].data = pr->res[i].data.p;
		e[n].len = pr->res[i].data.len;
		e[n++].enc = FP_ENC_ZLIB;
	}
	if (rc == 0) {
		e[n].path = "Distribution";
		e[n].data = dist->p;
		e[n].len = dist->len;
		e[n++].enc = FP_ENC_ZLIB;
		if ((rc = fp_xar_write_product(e, n, a->mtime, &out)) == 0)
			rc = fp_write_atomic(a->out, &out, -1);
	}
	for (i = 0; names != NULL && i < cap; i++)
		free(names[i]);
	free(names);
	free(e);
	fp_buf_free(&out);
	return rc;
}

int
fp_product(int argc, char **argv)
{
	struct args a;
	struct product pr;
	struct fp_xml_doc d;
	struct fp_buf dist = { 0 };
	size_t i, j;
	struct stat st;
	int k, rc;

	memset(&pr, 0, sizeof pr);
	memset(&d, 0, sizeof d);
	if ((rc = parse_args(argc, argv, &a)) != 0)
		goto out;
	if (a.res != NULL && (stat(a.res, &st) != 0 || !S_ISDIR(st.st_mode))) {
		fprintf(stderr, "stevedore: %s: --resources is not a directory\n", a.res);
		rc = 2;
		goto out;
	}
	pr.c = calloc(a.npkg, sizeof *pr.c);
	pr.order = calloc(a.npkg, sizeof *pr.order);
	if (pr.c == NULL || pr.order == NULL) {
		rc = oom();
		goto out;
	}
	for (i = 0; i < a.npkg; i++) {
		pr.c[i].path = a.pkg[i];
		pr.nc++;
		if ((rc = read_component(&pr.c[i])) != 0)
			goto out;
		for (j = 0; j < i; j++) {
			if (strcmp(pr.c[j].id, pr.c[i].id) == 0 || strcmp(pr.c[j].dir, pr.c[i].dir) == 0) {
				fprintf(stderr, "stevedore: %s and %s are both %s %s\n", pr.c[j].path, pr.c[i].path,
				    strcmp(pr.c[j].id, pr.c[i].id) == 0 ? "component" : "named",
				    strcmp(pr.c[j].id, pr.c[i].id) == 0 ? pr.c[i].id : pr.c[i].dir);
				rc = 2;
				goto out;
			}
		}
	}
	if ((rc = distribution(&pr, &a, &d)) != 0)
		goto out;
	if (fp_xml_write(&d, &dist) != 0) {
		rc = 1;
		goto out;
	}
	rc = write_product(&pr, &dist, &a);
out:
	for (i = 0; pr.c != NULL && i < pr.nc; i++) {
		for (k = 0; k < NMEMBER; k++)
			fp_buf_free(&pr.c[i].data[k]);
		fp_xml_free(&pr.c[i].info);
	}
	for (i = 0; i < pr.nres; i++)
		fp_buf_free(&pr.res[i].data);
	free(pr.c);
	free(pr.order);
	free(a.pkg);
	fp_xml_free(&d);
	fp_buf_free(&dist);
	return rc < 0 ? 1 : rc;
}
