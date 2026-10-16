# platform: host-agnostic
import importlib.util
import os
import platform

_host = os.environ.get("_PYTHON_HOST_PLATFORM", "").rpartition("-")[2]
_machine = _host if _host in ("x86_64", "arm64") else platform.machine()
if _machine not in ("x86_64", "arm64"):
    raise ImportError(f"{__name__} has build-time variables for x86_64 and arm64, not {_machine!r}")
_name = f"{__name__}_{_machine}"
_spec = importlib.util.spec_from_file_location(_name, os.path.join(os.path.dirname(__file__), f"{_name}.py"))
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)
build_time_vars = _module.build_time_vars
