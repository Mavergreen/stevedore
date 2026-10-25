# Build ingredients

Everything baked into what stevedore ships, and how a change to it reaches a release.

stevedore is **its own upstream**: it is versioned `YYYYMMDD.N` and nothing external releases it.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| stevedore's own source (own upstream) | `UPSTREAM_VERSION`: the date `self-upstream-version.sh` derives for own code | ❌ untrackable: nothing external releases it | bumping it on `main` is the decision to release |
| zlib, compiled into stevedore as a static library | `components/zlib/version` (the release) and `components/zlib/sha256` (its `zlib-<version>.tar.gz`) | ✅ github-releases manager tracks `madler/zlib` | the build fails at the fetch until `sh build/pin-zlib.sh` writes the new tarball's SHA-256; the gz fixtures are then regenerated if deflate's output moved |
| MacOSX10.9 and 11.3 SDKs, CMake modules and fetch scripts | `Mavergreen/shipyard@v1` | ✅ github-actions manager tracks the tag | `@v1` moves without the pin changing, so nothing repackages by itself |
| clang22, the compiler | the installed `/usr/local/mavergreen/clang22` on a Mac; Linux B's archive on Linux | ❌ untrackable here until the release workflow pins it | follows the toolchain the build host carries |

zlib is fetched from its GitHub release, `https://github.com/madler/zlib/releases/download/v<version>/zlib-<version>.tar.gz`,
and verified against `components/zlib/sha256` by shipyard's `shipyard_fetch_verified`. zlib publishes no checksum
file and its signatures need gpg, which 10.9 lacks, so the hash is pinned by hand from two sources that must agree.
For zlib 1.3.2, `bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16` is the SHA-256 of both
the GitHub release asset and `https://zlib.net/zlib-1.3.2.tar.gz`, and is the hash zlib.net's own page lists
for that tarball (checked 2026-10-25). `build/pin-zlib.sh` repeats the two-download check for a new version.

stevedore builds only zlib's deflate, inflate and checksum sources, with zlib's own `zconf.h`; the `gz*` file
functions are left out. Deflate runs at level 9, window 15, memLevel 8, the default strategy. The gzip member
is written by stevedore itself: MTIME 0, XFL 2, OS 3, no file name.

## Declared state

- upstream: UPSTREAM_VERSION
- zlib: components/zlib/version
- zlib-sha256: components/zlib/sha256

## Conformance deviations

- scheme: stevedore is its own upstream (no one else's release to repackage), so it versions itself by date as YYYYMMDD.N with no -mavericks.N axis
- on-target: no 10.9 acceptance job yet, since stevedore has no pkg yet; exit: the release workflow's vm-test job that installs the pkg on 10.9 and runs stevedore there
- self-upstream-exclude:release-notes/**: release-note sources; not in the product
- self-upstream-exclude:comment-reasons: the conventions gate's comment config; not in the product
- self-upstream-exclude:.claude/**: an agent's settings for working in this repo; not in the product

## Upstream release notes

No upstream release notes: stevedore is its own upstream, and a zlib bump is an ingredient move that the notes' Build ingredients section names.
