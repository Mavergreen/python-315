# Python 3.15 for Mavericks

**This README has not been read or edited by a human yet.** Until it has, this project cannot cut
its first release.

CPython 3.15, cross-built into a Mac OS X 10.9 (Mavericks)-compatible installer package. Phase 1
has no `ssl` module and no pip.

No `pip` command is installed. A virtual environment still gets one: `python3.15 -m venv` installs
pip from the wheel CPython bundles. That pip installs wheels you already have on disk, but without
`ssl` it cannot reach PyPI, and anything it would download fails with an error. A later phase adds
`ssl`.

This is an unofficial community build. It is not affiliated with, endorsed by or supported by the
Python Software Foundation.
