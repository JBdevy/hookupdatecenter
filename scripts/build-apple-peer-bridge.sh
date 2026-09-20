#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="$ROOT/native/apple-peer-bridge/main.swift"
OUTPUT_DIR="$ROOT/build/apple-peer-bridge"
ARM_BINARY="$OUTPUT_DIR/vshook-apple-peer-bridge-arm64"
INTEL_BINARY="$OUTPUT_DIR/vshook-apple-peer-bridge-x64"
UNIVERSAL_BINARY="$OUTPUT_DIR/vshook-apple-peer-bridge"

mkdir -p "$OUTPUT_DIR"
swiftc -O -target arm64-apple-macosx10.15 "$SOURCE" -o "$ARM_BINARY"
swiftc -O -target x86_64-apple-macosx10.15 "$SOURCE" -o "$INTEL_BINARY"
lipo -create "$ARM_BINARY" "$INTEL_BINARY" -output "$UNIVERSAL_BINARY"
chmod 755 "$UNIVERSAL_BINARY"
rm -f "$ARM_BINARY" "$INTEL_BINARY"
lipo -info "$UNIVERSAL_BINARY"
