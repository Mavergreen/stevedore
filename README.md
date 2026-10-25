# stevedore

**This README has not been read or edited by a human yet.** Until it has, this project cannot cut
its first release.

stevedore writes macOS flat installer packages, component packages and product archives, and reads
them back. The same inputs give the same bytes on Linux, Mac OS X 10.9 and modern macOS: nothing
about the host (time, owner, locale, file order, zlib build) reaches the output.

It is a family product of [Mavergreen](https://github.com/Mavergreen), written in C99 with no
runtime dependency beyond the C library. Its deflate is zlib at the version
`components/zlib/version` pins, compiled in; stevedore refuses to run if the zlib it was linked with
is any other.

## Building

    sh build/build.sh

configures and builds out of the tree and prints the build directory. On a Mac it builds for 10.9
(x86_64) through shipyard's `MavericksToolchain.cmake` with clang22; `ARCH=arm64` builds the arm64
slice. On Linux it is a native build; set `CC` to the compiler and `CMAKE` to the cmake to use.

The build fetches the pinned zlib release tarball once, verifies it against
`components/zlib/sha256`, and caches it, so later builds need no network.

## Testing

    sh "$SHIPYARD_SCRIPTS/run-repo-tests.sh"

runs every `tests/*.sh` against the build `build/build.sh` made (or the binary `STEVEDORE` names).

## Licence

Public domain (CC0 1.0, with the WTFPL where that is not possible); see `LICENSE`. zlib keeps its own licence.
