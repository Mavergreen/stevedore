#define _POSIX_C_SOURCE 200809L

#include "tree.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int
refuse(const char *reason, const char *path)
{
	fprintf(stderr, "stevedore: %s: %s\n", reason, path);
	return FP_REFUSED;
}

static int
oom(void)
{
	fputs("stevedore: out of memory\n", stderr);
	return -1;
}

static int
fail(const char *what, const char *path)
{
	fprintf(stderr, "stevedore: %s: %s: %s\n", what, path, strerror(errno));
	return -1;
}

static char *
join(const char *a, const char *b)
{
	size_t la = strlen(a), lb = strlen(b);
	char *s = malloc(la + lb + 2);

	if (s == NULL)
		return NULL;
	memcpy(s, a, la);
	s[la] = '/';
	memcpy(s + la + 1, b, lb + 1);
	return s;
}

static int
cmp_str(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

static int
cmp_entry(const void *a, const void *b)
{
	return strcmp(((const struct fp_entry *)a)->path, ((const struct fp_entry *)b)->path);
}

static int
add(struct fp_tree *t, char *path, unsigned long mode, unsigned long long size, char *target)
{
	struct fp_entry *e;

	if (t->n == t->cap) {
		size_t cap = t->cap ? t->cap * 2 : 16;

		e = realloc(t->e, cap * sizeof *e);
		if (e == NULL)
			return oom();
		t->e = e;
		t->cap = cap;
	}
	e = &t->e[t->n++];
	e->path = path;
	e->mode = mode;
	e->size = size;
	e->link_target = target;
	e->nchild = 0;
	return 0;
}

static int
classify(const struct stat *st, const char *rel, unsigned long *mode)
{
	unsigned long perm = (unsigned long)st->st_mode & 07777;

	if (S_ISDIR(st->st_mode))
		*mode = 040000 | perm;
	else if (S_ISREG(st->st_mode))
		*mode = 0100000 | perm;
	else if (S_ISLNK(st->st_mode))
		*mode = 0120755;
	else if (S_ISFIFO(st->st_mode))
		return refuse("fifo", rel);
	else if (S_ISSOCK(st->st_mode))
		return refuse("socket", rel);
	else
		return refuse("device", rel);
	if (!S_ISDIR(st->st_mode) && st->st_nlink > 1)
		return refuse("hard link", rel);
	return 0;
}

static int
walk(struct fp_tree *t, const char *dir, const char *rel, size_t idx)
{
	DIR *d;
	struct dirent *de;
	char **names = NULL, **nn;
	size_t n = 0, cap = 0, i;
	int rc = 0;

	d = opendir(dir);
	if (d == NULL)
		return fail("cannot read directory", rel);
	errno = 0;
	while ((de = readdir(d)) != NULL) {
		if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0
		    || strncmp(de->d_name, "._", 2) == 0)
			continue;
		if (n == cap) {
			nn = realloc(names, (cap ? cap * 2 : 16) * sizeof *names);
			if (nn == NULL) {
				rc = oom();
				break;
			}
			names = nn;
			cap = cap ? cap * 2 : 16;
		}
		names[n] = strdup(de->d_name);
		if (names[n] == NULL) {
			rc = oom();
			break;
		}
		n++;
		errno = 0;
	}
	if (rc == 0 && errno != 0)
		rc = fail("cannot read directory", rel);
	closedir(d);
	if (rc != 0)
		goto out;
	qsort(names, n, sizeof *names, cmp_str);
	t->e[idx].nchild = n;

	for (i = 0; i < n && rc == 0; i++) {
		char *fs = join(dir, names[i]), *r = join(rel, names[i]), *target = NULL;
		struct stat st;
		unsigned long mode;
		unsigned long long size;

		if (fs == NULL || r == NULL) {
			rc = oom();
		} else if (lstat(fs, &st) != 0) {
			rc = fail("cannot stat", r);
		} else if ((rc = classify(&st, r, &mode)) == 0) {
			size = S_ISREG(st.st_mode) ? (unsigned long long)st.st_size : 0;
			if (S_ISLNK(st.st_mode)) {
				ssize_t got;

				target = malloc((size_t)st.st_size + 1);
				if (target == NULL) {
					rc = oom();
				} else if ((got = readlink(fs, target, (size_t)st.st_size + 1)) < 0
				    || (off_t)got != st.st_size) {
					rc = fail("cannot read link", r);
				} else {
					target[got] = '\0';
					size = (unsigned long long)got;
				}
			}
			if (rc == 0 && add(t, r, mode, size, target) != 0)
				rc = oom();
			else if (rc == 0) {
				r = NULL;
				target = NULL;
				if (S_ISDIR(st.st_mode))
					rc = walk(t, fs, t->e[t->n - 1].path, t->n - 1);
			}
		}
		free(fs);
		free(r);
		free(target);
	}
out:
	for (i = 0; i < n; i++)
		free(names[i]);
	free(names);
	return rc;
}

int
fp_tree_scan(const char *root, struct fp_tree *t)
{
	struct stat st;
	unsigned long mode;
	char *dot;
	int rc;

	memset(t, 0, sizeof *t);
	if (stat(root, &st) != 0)
		return fail("cannot stat", root);
	if (!S_ISDIR(st.st_mode))
		return refuse("not a directory", root);
	if (classify(&st, ".", &mode) != 0)
		return -1;
	t->root = strdup(root);
	dot = strdup(".");
	if (t->root == NULL || dot == NULL || add(t, dot, mode, 0, NULL) != 0) {
		free(dot);
		fp_tree_free(t);
		return oom();
	}
	rc = walk(t, root, ".", 0);
	if (rc != 0) {
		fp_tree_free(t);
		return rc;
	}
	qsort(t->e, t->n, sizeof *t->e, cmp_entry);
	return 0;
}

void
fp_tree_free(struct fp_tree *t)
{
	size_t i;

	for (i = 0; i < t->n; i++) {
		free(t->e[i].path);
		free(t->e[i].link_target);
	}
	free(t->e);
	free(t->root);
	memset(t, 0, sizeof *t);
}

static int
cmp_dfs(const void *a, const void *b)
{
	const unsigned char *x = (const unsigned char *)(*(const struct fp_entry *const *)a)->path;
	const unsigned char *y = (const unsigned char *)(*(const struct fp_entry *const *)b)->path;
	unsigned cx, cy;

	for (;; x++, y++) {
		cx = *x == '/' ? 1 : *x == '\0' ? 0 : (unsigned)*x + 1;
		cy = *y == '/' ? 1 : *y == '\0' ? 0 : (unsigned)*y + 1;
		if (cx != cy || cx == 0)
			return cx < cy ? -1 : cx > cy;
	}
}

size_t *
fp_tree_dfs(const struct fp_tree *t)
{
	const struct fp_entry **p = malloc(t->n * sizeof *p);
	size_t *order = malloc(t->n * sizeof *order), i;

	if (p == NULL || order == NULL) {
		free(p);
		free(order);
		return NULL;
	}
	for (i = 0; i < t->n; i++)
		p[i] = &t->e[i];
	qsort(p, t->n, sizeof *p, cmp_dfs);
	for (i = 0; i < t->n; i++)
		order[i] = (size_t)(p[i] - t->e);
	free(p);
	return order;
}
