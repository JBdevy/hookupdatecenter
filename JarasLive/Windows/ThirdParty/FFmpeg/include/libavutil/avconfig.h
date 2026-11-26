#ifndef AVUTIL_AVCONFIG_H
#define AVUTIL_AVCONFIG_H

// Este arquivo normalmente e gerado por ./configure. A extensao usa apenas
// os headers publicos e carrega o runtime FFmpeg dinamicamente, portanto so
// precisa declarar as propriedades comuns aos alvos suportados: Windows x64,
// macOS x86_64 e macOS arm64.
#define AV_HAVE_BIGENDIAN 0
#define AV_HAVE_FAST_UNALIGNED 1

#endif
