# platform: host-agnostic
#   usage: . tests/fixtures/gz/inputs.sh; gz_inputs FIXTURE_DIR OUT_DIR
#          Writes the gz fixtures' inputs into OUT_DIR from FIXTURE_DIR/seed: empty, one-byte,
#          random-1mib (AES-128-CBC of zeros, keyed by the seed) and toc-text (xar-TOC-like XML whose
#          numbers come from a 24-bit LCG seeded by the seed's first six hex digits).
gz_inputs() {
  : > "$2/empty"
  printf 'x' > "$2/one-byte"
  dd if=/dev/zero bs=1024 count=1024 2>/dev/null \
    | openssl enc -aes-128-cbc -nopad -K "$(cat "$1/seed")" -iv 00000000000000000000000000000000 > "$2/random-1mib"
  awk -v seed="$(cut -c1-6 "$1/seed")" 'BEGIN {
    x = 0
    for (i = 1; i <= 6; i++) x = x * 16 + index("0123456789abcdef", substr(seed, i, 1)) - 1
    off = 0
    print "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    print "<xar>"
    print " <toc>"
    for (id = 1; id <= 2000; id++) {
      x = (x * 69069 + 1) % 16777216
      size = x % 65536
      mode = (x % 2) ? 493 : 420
      printf "  <file id=\"%d\">\n   <name>f%06x.dat</name>\n   <type>file</type>\n   <mode>%o</mode>\n", id, x, mode
      printf "   <uid>0</uid>\n   <gid>0</gid>\n   <user>root</user>\n   <group>wheel</group>\n"
      printf "   <data>\n    <length>%d</length>\n    <offset>%d</offset>\n    <size>%d</size>\n", size, off, size
      printf "    <encoding style=\"application/octet-stream\"/>\n   </data>\n  </file>\n"
      off += size
    }
    print " </toc>"
    print "</xar>"
  }' > "$2/toc-text"
}

gz_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -c1-64
  else openssl dgst -sha256 < "$1" | awk '{ print $NF }'
  fi
}
