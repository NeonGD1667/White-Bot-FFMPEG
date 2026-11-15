#!/usr/bin/env bash
# Usage: scripts/android.sh <arm64-v8a|armeabi-v7a>
# Needs the Android NDK (ANDROID_NDK_HOME / ANDROID_NDK_LATEST_HOME), a Linux host.
source "$(dirname "$0")/common.sh"

ABI="${1:?usage: android.sh <arm64-v8a|armeabi-v7a>}"
API=24
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:?set ANDROID_NDK_HOME}}"
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"

case "$ABI" in
  arm64-v8a)
    CC_TRIPLE="aarch64-linux-android$API"; ARCH=aarch64; X264_HOST=aarch64-linux-android
    ARCH_FLAGS=(--cpu=armv8-a); X264_ARCH_FLAGS=() ;;
  armeabi-v7a)
    CC_TRIPLE="armv7a-linux-androideabi$API"; ARCH=arm; X264_HOST=arm-linux-androideabi
    # no asm on 32-bit ARM: avoids text relocations
    ARCH_FLAGS=(--cpu=armv7-a --disable-asm); X264_ARCH_FLAGS=(--disable-asm) ;;
  *) echo "unknown ABI $ABI"; exit 1 ;;
esac

export CC="$TC/bin/$CC_TRIPLE-clang"
export CXX="$TC/bin/$CC_TRIPLE-clang++"
export AS="$CC"
PREFIX="$WORK/android-$ABI"
rm -rf "$PREFIX"; mkdir -p "$PREFIX"

fetch_ffmpeg
ffmpeg_common_flags

if [ "$WITH_X264" = "1" ]; then
  fetch_x264
  rm -rf "$WORK/x264-build-$ABI"; mkdir -p "$WORK/x264-build-$ABI"
  ( cd "$WORK/x264-build-$ABI"
    "$X264_SRC/configure" --prefix="$PREFIX" --host="$X264_HOST" --cross-prefix="$TC/bin/llvm-" \
      --sysroot="$TC/sysroot" --enable-static --enable-pic --disable-cli --disable-opencl \
      "${X264_ARCH_FLAGS[@]}"
    make -j"$JOBS" install )
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
  FF_FLAGS+=(--pkg-config-flags=--static)
fi

rm -rf "$WORK/ffmpeg-build-android-$ABI"; mkdir -p "$WORK/ffmpeg-build-android-$ABI"
cd "$WORK/ffmpeg-build-android-$ABI"
"$FFMPEG_SRC/configure" \
  --prefix="$PREFIX" "${FF_FLAGS[@]}" \
  --enable-cross-compile --target-os=android --arch="$ARCH" "${ARCH_FLAGS[@]}" \
  --cc="$CC" --cxx="$CXX" --ar="$TC/bin/llvm-ar" --nm="$TC/bin/llvm-nm" \
  --ranlib="$TC/bin/llvm-ranlib" --strip="$TC/bin/llvm-strip" --sysroot="$TC/sysroot" \
  --enable-jni --enable-mediacodec --enable-encoder=h264_mediacodec,hevc_mediacodec \
  --extra-cflags="-fPIC -O3 -I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib"
make -j"$JOBS"
make install

collect_libs "$PREFIX" "$ABI"
echo "Android $ABI done -> $OUT/lib/$ABI"
