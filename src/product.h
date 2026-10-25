#ifndef FP_PRODUCT_H
#define FP_PRODUCT_H

#define FP_PRODUCT_USAGE \
	"stevedore product --distribution XML --package PKG [--package PKG]... [--resources DIR]\n" \
	"           --mtime EPOCH --out PKG\n"

int fp_product(int argc, char **argv);

#endif
