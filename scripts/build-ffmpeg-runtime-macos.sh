#!/bin/bash
set -euo pipefail

FFMPEG_VERSION="8.1.2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="${1:-$PROJECT_ROOT/vendor/ffmpeg/ffmpeg-${FFMPEG_VERSION}-macos-universal-lgpl-shared.zip}"
SOURCE="${VSHOOK_FFMPEG_SOURCE:-$PROJECT_ROOT/../ffmpeg-${FFMPEG_VERSION}}"
WORK="$(mktemp -d /tmp/vshook-ffmpeg-build.XXXXXX)"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

if [ ! -x "$SOURCE/configure" ]; then
  ARCHIVE="$WORK/ffmpeg-${FFMPEG_VERSION}.tar.xz"
  curl --fail --location --retry 3 \
    "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
    --output "$ARCHIVE"
  tar -xJf "$ARCHIVE" -C "$WORK"
  SOURCE="$WORK/ffmpeg-${FFMPEG_VERSION}"
fi

SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"

build_arch() {
  local arch="$1"
  local minimum="$2"
  local build="$WORK/build-$arch"
  local prefix="$WORK/prefix-$arch"
  local asm_option=""
  local cross_option=""
  if [ "$arch" = "x86_64" ] && ! command -v nasm >/dev/null 2>&1 && ! command -v yasm >/dev/null 2>&1; then
    asm_option="--disable-x86asm"
  fi
  if [ "$(uname -m)" != "$arch" ]; then
    cross_option="--enable-cross-compile"
  fi
  mkdir -p "$build" "$prefix"
  (
    cd "$build"
    "$SOURCE/configure" \
      --prefix="$prefix" \
      --target-os=darwin \
      --arch="$arch" \
      --cc=clang \
      --sysroot="$SDK_ROOT" \
      --install-name-dir=@rpath \
      --disable-static \
      --enable-shared \
      --disable-ffplay \
      --disable-doc \
      --disable-debug \
      --disable-avdevice \
      --disable-gpl \
      --disable-nonfree \
      --enable-videotoolbox \
      --enable-audiotoolbox \
      --extra-cflags="-arch $arch -mmacosx-version-min=$minimum" \
      --extra-ldflags="-arch $arch -mmacosx-version-min=$minimum" \
      $cross_option \
      $asm_option
    make -j"$JOBS"
    make install
  )
}

build_arch x86_64 10.13
build_arch arm64 11.0

STAGE="$WORK/stage/FFmpeg"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/licenses"
cp "$SOURCE/COPYING.LGPLv2.1" "$STAGE/licenses/"
cp "$SOURCE/COPYING.LGPLv3" "$STAGE/licenses/"
cat > "$STAGE/licenses/SOURCE.txt" <<EOF
FFmpeg ${FFMPEG_VERSION}
Source: https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz
Configuration: LGPL shared libraries, no --enable-gpl and no --enable-nonfree.
EOF

SIGN_IDENTITY="${VSHOOK_MACOS_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Developer ID Application:/ { print $2; exit }')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  echo "Certificado Developer ID Application não encontrado para assinar o runtime FFmpeg." >&2
  exit 1
fi

for x86_library in "$WORK/prefix-x86_64/lib/"*.dylib; do
  [ -L "$x86_library" ] && continue
  name="$(basename "$x86_library")"
  arm_library="$WORK/prefix-arm64/lib/$name"
  [ -f "$arm_library" ] || continue
  lipo -create "$x86_library" "$arm_library" -output "$STAGE/lib/$name"
  install_name_tool -add_rpath @loader_path "$STAGE/lib/$name" 2>/dev/null || true
  codesign --force --timestamp --options runtime \
    --sign "$SIGN_IDENTITY" "$STAGE/lib/$name"
  codesign --verify --strict "$STAGE/lib/$name"
done

for program in ffmpeg; do
  x86_program="$WORK/prefix-x86_64/bin/$program"
  arm_program="$WORK/prefix-arm64/bin/$program"
  [ -x "$x86_program" ] && [ -x "$arm_program" ] || {
    echo "Executável ausente no runtime universal: $program" >&2
    exit 1
  }
  lipo -create "$x86_program" "$arm_program" -output "$STAGE/bin/$program"
  install_name_tool -add_rpath @executable_path/../lib "$STAGE/bin/$program" 2>/dev/null || true
  codesign --force --timestamp --options runtime \
    --sign "$SIGN_IDENTITY" "$STAGE/bin/$program"
  codesign --verify --strict "$STAGE/bin/$program"
done

for link in "$WORK/prefix-arm64/lib/"*.dylib; do
  [ -L "$link" ] || continue
  name="$(basename "$link")"
  target="$(readlink "$link")"
  [ -f "$STAGE/lib/$target" ] || continue
  ln -s "$target" "$STAGE/lib/$name"
done

for required in \
  libavutil.60.dylib \
  libswresample.6.dylib \
  libavcodec.62.dylib \
  libavformat.62.dylib \
  libavfilter.11.dylib \
  libswscale.9.dylib; do
  [ -f "$STAGE/lib/$required" ] || {
    echo "Biblioteca ausente no runtime universal: $required" >&2
    exit 1
  }
done

for program in ffmpeg; do
  [ -x "$STAGE/bin/$program" ] || {
    echo "Executável ausente no pacote universal: $program" >&2
    exit 1
  }
done

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
(
  cd "$WORK/stage"
  /usr/bin/zip -qry "$OUTPUT" FFmpeg
)
echo "Runtime FFmpeg universal criado em $OUTPUT"
