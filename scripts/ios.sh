#!/usr/bin/env bash
# Usage: scripts/ios.sh      (macOS host with Xcode). Produces out/lib/ios-arm64/
source "$(dirname "$0")/common.sh"

MIN_IOS="${MIN_IOS:-14.0}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC_STR="xcrun --sdk iphoneos clang"
ARCH_FLAGS="-arch arm64 -miphoneos-version-min=$MIN_IOS -isysroot $SDK"
PREFIX="$WORK/ios-arm64"
rm -rf "$PREFIX"; mkdir -p "$PREFIX"

fetch_ffmpeg
ffmpeg_common_flags

if [ "$WITH_X264" = "1" ]; then
  fetch_x264
  rm -rf "$WORK/x264-build-ios"; mkdir -p "$WORK/x264-build-ios"
  ( cd "$WORK/x264-build-ios"
    export CC="$CC_STR $ARCH_FLAGS"
    export AS="$CC_STR $ARCH_FLAGS"
    "$X264_SRC/configure" --prefix="$PREFIX" --host=aarch64-apple-darwin \
      --enable-static --enable-pic --disable-cli --disable-opencl
    make -j"$JOBS" install )
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
  FF_FLAGS+=(--pkg-config-flags=--static)
fi

rm -rf "$WORK/ffmpeg-build-ios"; mkdir -p "$WORK/ffmpeg-build-ios"
cd "$WORK/ffmpeg-build-ios"
"$FFMPEG_SRC/configure" \
  --prefix="$PREFIX" "${FF_FLAGS[@]}" \
  --enable-cross-compile --target-os=darwin --arch=arm64 \
  --cc="$CC_STR" --as="$CC_STR" \
  --enable-videotoolbox --enable-encoder=h264_videotoolbox,hevc_videotoolbox \
  --extra-cflags="$ARCH_FLAGS -O3 -I$PREFIX/include" --extra-ldflags="$ARCH_FLAGS -L$PREFIX/lib"
make -j"$JOBS"
make install

collect_libs "$PREFIX" ios-arm64
echo "iOS done -> $OUT/lib/ios-arm64"
