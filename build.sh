#!/usr/bin/env bash
# Build ShuDong.dylib for iOS (arm64 + arm64e) using only the iphoneos SDK, then
# package it as jailbreak .deb tweaks.
#
# The tweak is plain Objective-C runtime swizzling: no Theos, no CydiaSubstrate,
# so the dylib works with TrollFools injection (on a decrypted app) and inside a
# .deb tweak alike.
set -euo pipefail

NAME="ShuDong"
VERSION="1.0.1"
MIN_IOS="14.0"
SRC_DIR="src"
LAYOUT_DIR="layout"
OUT_DIR="build"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

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

# ---------------------------------------------------------------- deb packaging
# Two package flavours, identical payload, different Architecture field:
#   iphoneos-arm64e -> roothide Dopamine
#   iphoneos-arm64  -> rootless Dopamine / Ellekit (/var/jb)
# Paths inside the deb are jbroot-relative, which is what rootless and roothide
# dpkg both expect.
if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "!! dpkg-deb not found, skipping .deb packaging (brew install dpkg)" >&2
  echo "Done: $OUT_DIR/$NAME.dylib"
  exit 0
fi

for DEB_ARCH in iphoneos-arm64e iphoneos-arm64; do
  echo "==> packaging $DEB_ARCH"
  STAGE="$OUT_DIR/stage-$DEB_ARCH"
  rm -rf "$STAGE"
  mkdir -p "$STAGE/usr/lib/TweakInject" "$STAGE/DEBIAN"

  cp "$OUT_DIR/$NAME.dylib" "$STAGE/usr/lib/TweakInject/$NAME.dylib"
  cp "$LAYOUT_DIR/usr/lib/TweakInject/$NAME.plist" "$STAGE/usr/lib/TweakInject/$NAME.plist"
  chmod 0644 "$STAGE/usr/lib/TweakInject/$NAME.plist"
  chmod 0755 "$STAGE/usr/lib/TweakInject/$NAME.dylib"

  sed "s/^Architecture: .*/Architecture: $DEB_ARCH/; s/^Version: .*/Version: $VERSION/" \
    "$LAYOUT_DIR/DEBIAN/control" > "$STAGE/DEBIAN/control"
  for SCRIPT in postinst postrm; do
    if [ -f "$LAYOUT_DIR/DEBIAN/$SCRIPT" ]; then
      cp "$LAYOUT_DIR/DEBIAN/$SCRIPT" "$STAGE/DEBIAN/$SCRIPT"
      chmod 0755 "$STAGE/DEBIAN/$SCRIPT"
    fi
  done
  chmod 0755 "$STAGE/DEBIAN"

  dpkg-deb -Zgzip --root-owner-group -b "$STAGE" \
    "$OUT_DIR/${NAME}_${VERSION}_${DEB_ARCH}.deb"
  rm -rf "$STAGE"
done

rm -rf "$OUT_DIR"/stage-*
ls -la "$OUT_DIR"
echo "Done: $OUT_DIR/$NAME.dylib + debs"
