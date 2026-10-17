# Python 3.15 for Mavericks

**This README has not been read or edited by a human yet.** Until it has, this project cannot cut
its first release.

CPython 3.15, cross-built into a Mac OS X 10.9 (Mavericks)-compatible installer package. Phase 1
has no `ssl` module and no pip.

`python3-315` and `python-315` are always on the family's `PATH` (`/usr/local/mavergreen/bin`, which
login shells get from `/etc/paths.d`). The bare `python3`, `python3.15` and `python` belong to the
selected Python line (`mavergreen select python`). Login shells search `/usr/bin` first, so on 10.9 a
bare `python` still finds the system's Python 2.7 and `python3` finds this one, and on modern macOS a
bare `python3` finds Apple's `/usr/bin/python3` and `python` finds this one.

No `pip` command is installed. A virtual environment still gets one: `python3.15 -m venv` installs
pip from the wheel CPython bundles. That pip installs wheels you already have on disk, but without
`ssl` it cannot reach PyPI, and anything it would download fails with an error. A later phase adds
`ssl`.

Another family product's packages, installed under `/usr/local/mavergreen/<product>/lib/python3.15/site-packages`,
are importable without being copied in: a `.pth` file adds each such directory to `sys.path`. Those
directories' own `.pth` files are not processed.

This is an unofficial community build. It is not affiliated with, endorsed by or supported by the
Python Software Foundation.
