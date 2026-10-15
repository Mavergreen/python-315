# Build ingredients

Everything baked into the shipped `.pkg`, and how a change to it reaches a release. An *ingredient*
is an input to the product; the *own upstream* is the thing this repo exists to port.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| CPython (own upstream) | `UPSTREAM_VERSION` | ✅ `github-tags` on `python/cpython`, capped to `<3.16` | `release.yml` on push to main cuts `-mavericks.1` |
| SQLite (amalgamation, static `libsqlite3.a`) | `components/sqlite/version` (`VERSION`, `YEAR`, `SHA256`) | ✅ `github-tags` on `sqlite/sqlite` moves `VERSION`; `YEAR` and `SHA256` move by hand | repackage → `-mavericks.(N+1)` |
| xz (static `liblzma.a`) | `components/xz/version` (`TAG`, `SHA256`) | ✅ `github-release-attachments` on `tukaani-project/xz` moves the tag and its SHA-256 together | repackage |
| zstd (static `libzstd.a`) | `components/zstd/version` | ✅ `github-releases` on `facebook/zstd` | repackage |
| clang22 (the compiler: the cross pkg off 10.9, the installed release on 10.9) | `components/clang22/version` | ✅ `github-releases` on `Mavergreen/clang-22`, `-mavericks.N` versioning | repackage |
| Recaulk (`librecaulk.a`, linked into the x86_64 build) | `components/recaulk/version` | ✅ shipyard preset manager, `github-releases` on `Mavergreen/recaulk` | repackage |
| MacOSX10.9 and 11.3 SDKs, Sparkle framework | `Mavergreen/shipyard@v1` | ✅ github-actions manager tracks the tag | `@v1` is a moving tag, so content moves without a path changing |

## How each ingredient is verified

A native 10.9 build verifies every download with the OS's own `shasum`, so it checks only what that
can: SHA-1 or SHA-256, never a GPG signature or SHA3. `build/fetch-ingredient.sh` does the fetching.

- **zstd:** against the `zstd-<version>.tar.gz.sha256` upstream attaches to each release, fetched
  afresh every run. A tarball the file does not list fails.
- **xz:** against the SHA-256 pinned in `components/xz/version`. Upstream signs its tarballs with GPG
  and publishes no checksum. The 5.8.4 pin matched GitHub's own asset digest when it was recorded.
- **SQLite:** against the SHA-256 pinned in `components/sqlite/version`. sqlite.org publishes only
  SHA3-256. The 3.54.0 pin was recorded from a tarball whose SHA3-256 and size matched sqlite.org's.
  A Renovate bump fails at the fetch, naming the SHA-256 it got, until `YEAR` and `SHA256` follow.
- **clang22, Recaulk:** shipyard's `fetch_product_pkg.sh`, against each release's `SHA256SUMS`. On
  10.9 the installed clang22 is used instead, and the build stops unless it is the pinned release.

## How the static libraries are built

`build/build-deps.sh` compiles each file itself with clang22, so a 10.9 box needs no `make`. xz's
`configure` runs only to write `config.h`, in the same hermetic environment.

- **SQLite:** `sqlite3.c` with FTS3 parentheses, FTS4, FTS5, R*Tree and the math functions: the
  python.org macOS installer's options, plus the math functions.
- **liblzma:** every source upstream's `make` compiles under `configure`'s defaults: all of
  `src/liblzma` except the `--enable-small` variants, the table generators and the x86-32 assembly.
- **libzstd:** upstream's default library (common, compress, decompress, dictBuilder, legacy v0.5 to
  v0.7, the x86-64 assembly), built multithreaded as upstream builds its dylib, so
  `compression.zstd` can use worker threads.

An archive that defines a symbol twice fails the build.

## Declared state

- upstream: UPSTREAM_VERSION
- clang22: components/clang22/version
- recaulk: components/recaulk/version
- sqlite: components/sqlite/version
- xz: components/xz/version
- zstd: components/zstd/version

## Conformance deviations

- floor:python315-*-arm64*.pkg: shipyard's checks run on modern Macs, so the arm64 slice's install floor is 11.0, not 10.9.5. A native 10.9 build ships x86_64 only; CI supplies arm64 until native clang22 has AArch64.
