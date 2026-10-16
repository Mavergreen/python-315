#if defined(__x86_64__)
#include "pyconfig-x86_64.h"
#elif defined(__arm64__)
#include "pyconfig-arm64.h"
#else
#error "this Python carries pyconfig.h for x86_64 and arm64 only"
#endif
