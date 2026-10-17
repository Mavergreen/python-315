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
| GNU make (build-only: runs CPython's Makefile, and nothing of it ships) | `components/make/version` (`VERSION`, `SHA256`) | ✅ `git-tags` on GNU's `make.git` moves `VERSION`; `SHA256` moves by hand | no release: nothing shipped changes. Retires when the family ships a make product, which the build then takes as a tool |

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
- **GNU make:** against the SHA-256 pinned in `components/make/version`. GNU signs its tarballs with
  GPG and publishes no checksum. The 4.4.1 pin was recorded from a tarball whose SHA-512 and size
  matched pkgsrc's `devel/gmake/distinfo`. A Renovate bump fails at the fetch, naming the SHA-256 it
  got, until `SHA256` follows.
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

## How CPython is built

`build/build-python.sh` runs CPython's own `configure` and `make` from the release tarball's
generated files, in the same hermetic environment as the static libraries, with a GNU make that
`build/build-make.sh` builds from the pin with clang22 and make's own `build.sh`: a 10.9 box without
the Command Line Tools has no make, and the hermetic `PATH` keeps out any other.

- **Flags:** `--enable-shared --without-ensurepip --with-readline=editline --without-system-libmpdec`,
  plus `--without-static-libpython`. A static `libpython3.15.a` would carry calls to Recaulk's
  back-fills without Recaulk, so a program linked against it alone fails on 10.9; embedders link
  the dylib. `--with-openssl=/nonexistent` stops configure looking for OpenSSL in the build host's
  `/usr/local/ssl`, `/usr/pkg`, `/usr/local` and `/usr`, which would put those paths in the installed
  build configuration; it goes when OpenSSL becomes an ingredient. A native build presets
  `PYTHON_FOR_REGEN=/usr/bin/false`, so a target that regenerates sources fails instead of running
  whatever `python` the host has.
- **Ingredients:** the static libraries through `CPPFLAGS` and `LDFLAGS`, and on x86_64 Recaulk's
  headers and `librecaulk.a`. `libpython3.15.dylib` exports Recaulk's back-fills (`clock_gettime`,
  `openat`, ...) and hides Recaulk's internals.
- **Modules:** `Modules/Setup.local` disables `_ssl` and `_hashlib` (no OpenSSL in this release:
  `hashlib` uses CPython's built-in HACL\* code), and `_tkinter` and `_gdbm`, which are not offered.
- **Install names:** `libpython3.15.dylib` is `@rpath/libpython3.15.dylib`, and each Mach-O that
  loads it finds it through an rpath relative to itself, so the tree is relocatable. `python3.15`
  alone has a second rpath after that one, `/usr/local/mavergreen/python315/lib`: a venv's copied
  interpreter (`venv.create()`, `python3.15 -m venv --copies`) has no `lib` beside it, and finds
  libpython there. The smoke test allows that one absolute path, on that one file.
- **No C++:** nothing in this build compiles or links C++, and `tests/smoke-test.sh` fails if a
  Mach-O loads a C++ runtime, since clang22's `CXX` here has no 10.9 libc++ handling.
- **Patches:** each file in `patches/` says why it exists and when to drop it.
- **Cross builds:** only x86_64 cross-builds (from an arm64 Mac); arm64 builds natively. The cross
  build passes `configure` the answers its run tests give natively for x86_64 on 10.9, measured by
  comparing a native and a cross `pyconfig.h`, which came out identical.
- **Installed build configuration:** `build/rewrite-config.sh` rewrites every installed text file that
  names a build-host path (`_sysconfigdata`, the `_sysconfig_vars` JSON, the config `Makefile`,
  `config.c`, the pkgconfig files), so a C extension built later against this Python reaches nothing
  on the builder's machine. clang22 becomes `/usr/local/mavergreen/clang22`, with the same target
  flags. On x86_64 the SDK becomes `/usr/local/mavergreen/sdk109/SDKs/MacOSX10.9.sdk`, where Longboat
  installs it; the family has no arm64 SDK path, so arm64 loses `-isysroot`, and an arm64 extension
  build needs `SDKROOT` set: `CC` carries `--no-default-config` and clang22 never runs `xcrun`. The
  static libraries' and Recaulk's flags go, since python links them already, and the source and
  build directories become `LIBPL`, as sysconfig itself reports `srcdir` for an installed Python. `LIBDIR` stays the install path. Debug info names sources and objects relative to
  the work directory (`-ffile-prefix-map`, `-oso_prefix`), not stripped, and configure runs by a
  relative path from the build directory, upstream's out-of-tree form, so the `VPATH` that `getpath.c`
  compiles in is relative too. The build fails if any
  installed file, text or Mach-O, still names the build root, `$HOME`, `Library/Caches` or
  `/var/folders`, and so does `tests/contamination-test.sh`.
- **Universal tree:** `build/merge.sh` merges the x86_64 and arm64 stages with shipyard's
  `lipo-merge-tree.sh`. `pyconfig.h` and `_sysconfigdata__darwin_darwin.py` differ by arch, so the
  merged tree carries each slice's copy and picks by `__x86_64__`/`__arm64__`, and by the machine in
  `_PYTHON_HOST_PLATFORM` (a cross build's target) or else `platform.machine()`, loading the slice's
  module from its own directory. Three more per-arch files cannot pick at run time: the
  `_sysconfig_vars` JSON,
  `build-details.json` and the config `Makefile` ship as `<file>.x86_64` and `<file>.arm64`, listed in
  `lib/python3.15/mavergreen-arch-files.txt`, and `build/link-arch-files.sh` links each plain name to
  the installing Mac's arch. Any other non-Mach-O file that differs stops the merge, naming it. The merged
  python recompiles the library as checked-hash `.pyc` files: compiling the same source twice does not
  always give the same bytes, and the merge does not keep source mtimes. `tests/slice-parity-test.sh`
  checks that both slices have the same extension modules and every required module.
- **Tests:** x86_64 runs on-target, never under Rosetta: on a host that cannot run a stage's arch
  natively, `tests/smoke-test.sh` runs only its static checks.

## How the pkg is made

`build/package-pkg.sh` packages one stage, universal from `build/merge.sh` in CI or x86_64 alone from
a native 10.9 build, as `python-<version>.pkg`: shipyard's `dev.mavergreen.base`, then
`dev.mavergreen.python.python315`, with the 10.9.5 install floor and the Installer host arches that
`python3.15` itself carries, so Apple Silicon installs a universal pkg natively.

- **Pruned:** IDLE (`bin/idle3*`, `idlelib`), `tkinter` and `turtledemo`, since `_tkinter` is not built
  and there is no Tcl/Tk.
- **The test suite ships apart,** as `python-<version>-tests.tar.gz`: `lib/python3.15/test/` without
  bytecode, 7.5 MB against the 40 MB it adds to the pkg with its three levels of `.pyc` files, on every
  update. Unpacked into an installed prefix (`tar -xzof <tarball> -C /usr/local/mavergreen/python315`)
  it gives the layout `tests/regrtest.sh` measured its known failures against. An upgrade removes it
  with the rest of the tree. It is reproducible: an mtree spec, which 10.9's bsdtar 2.8.3 reads, gives
  sorted entries owned by root:wheel and dated `SOURCE_DATE_EPOCH` (default 0), and `gzip -n` adds no
  name or time.
- **Exports:** `bin/python` is added, linking to `python3.15`, and only `python`, `python3` and
  `python3.15` are exported: the helper links each as `<name>-315` always and bare while python315 is
  selected. `pydoc3` and `python3-config` stay in the tree, by absolute path. Every manpage is
  exported.
- **Per-arch files:** for a universal tree the postinstall runs `libexec/link-arch-files.sh`, shipped
  in the tree, for arm64 when `hw.optional.arm64` is 1 and x86_64 otherwise, on Installer's target
  volume. A tree moved to a Mac of the other arch is relinked by running it again.

## How the updater is built

`CMakeLists.txt` is the Sparkle updater, "Mavericks Python 3.15", with the generic app icon by
explicit opt-in. `build/build-updater.sh` builds it with clang22 (`RequireAppleClang` off), like
everything else this repo compiles, once per arch, and merges the two into one universal app. Its
public key is the family's, in `updater/ed25519_key.pub`.

## Declared state

- upstream: UPSTREAM_VERSION
- clang22: components/clang22/version
- recaulk: components/recaulk/version
- sqlite: components/sqlite/version
- xz: components/xz/version
- zstd: components/zstd/version

