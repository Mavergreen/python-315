# platform: host-agnostic
import os
import sys


def _discover():
    root = "/usr/local/mavergreen"
    env = "" if sys.flags.ignore_environment else os.environ.get("MAVERGREEN_ROOT", "")
    if os.path.isabs(env):
        root = env
    sub = os.path.join("lib", "python%d.%d" % sys.version_info[:2], "site-packages")
    seen = {os.path.realpath(p) for p in sys.path}
    found = []
    for product in sorted(os.listdir(root)):
        path = os.path.join(root, product, sub)
        real = os.path.realpath(path)
        if real not in seen and os.path.isdir(path):
            seen.add(real)
            found.append(path)
    return found


try:
    sys.path.extend(_discover())
except Exception:
    pass
