#pragma once
// MSVC x64 build configuration for the unmodified LAME 3.100 encoder.
// No assembly, mpg123 decoder, platform devices or external dependencies.
#include <stdint.h>
#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_LIMITS_H 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STRCHR 1
#define HAVE_MEMCPY 1
#define LAME_LIBRARY_BUILD 1
#define PACKAGE "lame"
#define PACKAGE_VERSION "3.100"
#define VERSION "3.100"
#define SIZEOF_DOUBLE 8
#define SIZEOF_FLOAT 4
#define SIZEOF_INT 4
#define SIZEOF_LONG 4
#define SIZEOF_LONG_DOUBLE 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF_SHORT 2
#define SIZEOF_UNSIGNED_INT 4
#define SIZEOF_UNSIGNED_LONG 4
#define SIZEOF_UNSIGNED_LONG_LONG 8
#define SIZEOF_UNSIGNED_SHORT 2
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;
typedef long double ieee854_float80_t;
