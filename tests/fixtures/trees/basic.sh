# platform: host-agnostic
#   usage: . tests/fixtures/trees/basic.sh; basic_tree DIR
#          Builds the basic staged tree in the empty directory DIR: a symlink, an empty directory, a
#          name with a space and UTF-8, a 0-byte file, an executable, a 0700 directory, and names whose
#          byte order differs from their directory-walk order (a, a-b, a/b, B). Every mode and mtime is
#          set explicitly (mtime 2023-01-01 12:00 UTC), so the checkout does not matter. A symlink's own mode is host-dependent (the umask at ln -s on macOS, 0777 on Linux) and the payload writes 0755 for it regardless.
#          Regenerate tests/fixtures/trees/basic.payload.sha256 with:
#            T=$(mktemp -d); mkdir $T/tree; . tests/fixtures/trees/basic.sh; basic_tree $T/tree
#            stevedore payload --root $T/tree --mtime 1700000000 --out $T/p
#            sha256sum $T/p | cut -c1-64 > tests/fixtures/trees/basic.payload.sha256
basic_tree() {
  (
    cd "$1"
    mkdir a a/b a/c a/c/d "sp ace" emp
    printf 'hello\n' > a/hello.txt
    : > a/zero
    printf '#!/bin/sh\nexit 0\n' > a/run.sh
    printf 'dash\n' > a-b
    printf 'upper\n' > B
    printf 'utf8\n' > "sp ace/жук€.txt"
    ln -s a/hello.txt link
    chmod 755 . a a/b a/c a/c/d "sp ace" a/run.sh
    chmod 644 a/hello.txt a/zero a-b B "sp ace/жук€.txt"
    chmod 700 emp
    TZ=UTC touch -h -t 202301011200 . a a/b a/c a/c/d "sp ace" emp a/hello.txt a/zero a/run.sh a-b B "sp ace/жук€.txt" link
  )
}
