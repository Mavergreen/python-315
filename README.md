# Python 3.15 for Mavericks

Python runtime for Mac OS X 10.9 Mavericks.

## Building C extensions

The installed `sysconfig` names the family's compiler and pinned SDK for each architecture, so an
extension build needs both:

- x86_64: [clang22](https://github.com/Mavergreen/clang-22) and `sudo longboat install 10.9`
- arm64: clang22-cross (from the same releases) and `sudo longboat install 11.3`

[Longboat](https://github.com/Mavergreen/longboat) installs the SDKs.

## Not yet included

Just getting bootstrapped here. A future update will have these:

- `ssl`
- `pip`
