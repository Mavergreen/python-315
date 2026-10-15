# Build ingredients

Everything baked into the shipped `.pkg`, and how a change to it reaches a release. An *ingredient*
is an input to the product; the *own upstream* is the thing this repo exists to port.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| CPython (own upstream) | `UPSTREAM_VERSION` | ✅ `github-tags` on `python/cpython`, capped to `<3.16` | `release.yml` on push to main cuts `-mavericks.1` |
| SQLite, xz, zstd | added in a later task | pending | pending |
| clang22, Recaulk | added in a later task | pending | pending |
| MacOSX10.9 and 11.3 SDKs, Sparkle framework | `Mavergreen/shipyard@v1` | ✅ github-actions manager tracks the tag | `@v1` is a moving tag, so content moves without a path changing |

## Declared state

- upstream: UPSTREAM_VERSION

## Conformance deviations

- floor:python315-*-arm64*.pkg: shipyard's checks run on modern Macs, so the arm64 slice's install floor is 11.0, not 10.9.5. A native 10.9 build ships x86_64 only; CI supplies arm64 until native clang22 has AArch64.
