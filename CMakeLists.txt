cmake_minimum_required(VERSION 3.16)
# usage: build/build-updater.sh configures this once per arch and merges the apps.
project(PythonUpdater LANGUAGES OBJC)

find_package(MavericksShipyard REQUIRED)
# spec: INGREDIENTS.md "How the updater is built" -- clang22, like everything else this repo compiles
set(MAVERICKS_REQUIRE_APPLECLANG OFF)
include(Mavericks)
include(MavericksSparkle)

mavericks_resolve_version(PY_VERSION)
string(REGEX REPLACE "^([0-9]+)\\.([0-9]+)\\..*$" "\\1\\2" PY_LINE "${PY_VERSION}")
string(REGEX REPLACE "^([0-9]+)\\.([0-9]+)\\..*$" "\\1.\\2" PY_MINOR "${PY_VERSION}")
if(NOT PY_LINE MATCHES "^[0-9]+$")
  message(FATAL_ERROR "cannot derive the Python line from the version '${PY_VERSION}'")
endif()

mavericks_add_updater_app(
  PRODUCT python${PY_LINE}
  PRODUCT_NAME "Mavericks Python ${PY_MINOR}"
  ALLOW_GENERIC
  VERSION "${PY_VERSION}"
  LOG_PREFIX "MavPythonUpdater"
  CONFIRM_TITLE "Mavericks Python ${PY_MINOR} updated"
  CONFIRM_BODY "Python ${PY_MINOR} in /usr/local/mavergreen/python${PY_LINE} was updated."
  RELAUNCH_MARKER "/tmp/.mavericks-python${PY_LINE}-updater-relaunched"
)
