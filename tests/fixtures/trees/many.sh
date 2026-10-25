# platform: host-agnostic
#   usage: . tests/fixtures/trees/many.sh; many_tree DIR
#          Builds a staged tree in the empty directory DIR with 1202 paths, more than one 4096-byte BOM
#          B-tree leaf holds, so the Paths tree needs several leaves under an index node. Modes and
#          mtimes (2023-01-01 12:00 UTC) are set explicitly.
#          Regenerate tests/fixtures/trees/many.bom.sha256 with:
#            T=$(mktemp -d); mkdir $T/tree; . tests/fixtures/trees/many.sh; many_tree $T/tree
#            stevedore bom --root $T/tree --mtime 1700000000 --out $T/b
#            sha256sum $T/b | cut -c1-64 > tests/fixtures/trees/many.bom.sha256
many_tree() {
  (
    cd "$1"
    mkdir d
    i=0
    while [ "$i" -lt 1200 ]; do
      printf '%s\n' "$i" > "d/f$i"
      i=$((i + 1))
    done
    chmod 755 . d
    chmod 644 d/*
    TZ=UTC touch -t 202301011200 . d d/*
  )
}
