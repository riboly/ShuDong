#!/usr/bin/env bash
# Build ShuDong.dylib for iOS (arm64 + arm64e) using only the iphoneos SDK.
# The tweak is plain Objective-C runtime swizzling: no Theos, no CydiaSubstrate,
# so the dylib works with TrollFools injection and inside a .deb tweak alike.
set -euo pipefail

NAME="ShuDong"
MIN_IOS="14.0"
SRC_DIR="src"
OUT_DIR="build"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/$NAME.dylib" "$OUT_DIR/$NAME.zip"

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$SRC_DIR" -name '*.m' | sort)
echo "Sources: ${SOURCES[*]}"

for ARCH in arm64 arm64e; do
  echo "==> building $ARCH"
  "$CLANG" -arch "$ARCH" -mios-version-min="$MIN_IOS" \
    -isysroot "$SDK_PATH" \
    -dynamiclib -fobjc-arc -O2 \
    -Wall -Werror=implicit-function-declaration \
    -Wno-deprecated-declarations \
    -framework Foundation -framework UIKit \
    -install_name "@rpath/$NAME.dylib" \
    "${SOURCES[@]}" \
    -o "$OUT_DIR/$NAME-$ARCH.dylib"
done

echo "==> creating fat dylib"
xcrun lipo -create "$OUT_DIR/$NAME-arm64.dylib" "$OUT_DIR/$NAME-arm64e.dylib" \
  -output "$OUT_DIR/$NAME.dylib"
rm -f "$OUT_DIR/$NAME-arm64.dylib" "$OUT_DIR/$NAME-arm64e.dylib"

echo "==> ad-hoc signing"
if command -v ldid >/dev/null 2>&1; then
  ldid -S "$OUT_DIR/$NAME.dylib"
else
  codesign -f -s - "$OUT_DIR/$NAME.dylib"
fi

( cd "$OUT_DIR" && zip -q "$NAME.zip" "$NAME.dylib" )
xcrun lipo -info "$OUT_DIR/$NAME.dylib"
echo "Done: $OUT_DIR/$NAME.dylib"
