#ifndef FP_COMPONENT_H
#define FP_COMPONENT_H

#define FP_COMPONENT_USAGE \
	"stevedore component {--root DIR | --nopayload} --identifier ID --version V --install-location LOC\n" \
	"           --mtime EPOCH [--scripts DIR] --out PKG\n" \
	"           (a bundle's Info.plist that is unreadable or neither xml1 nor binary1 exits 2)\n"

int fp_component(int argc, char **argv);

#endif
