#!/usr/bin/env bash
# Usage: scripts/macos.sh    (macOS host, needs nasm). Builds arm64 + x86_64 and merges with lipo
# into out/lib/macos-universal/ (White Bot builds both architectures).
source "$(dirname "$0")/common.sh"

MIN_MAC="${MIN_MAC:-11.0}"
fetch_ffmpeg
if [ "$WITH_X264" = "1" ]; then fetch_x264; fi

build_arch() {
  local arch="$1" x264_host
  local prefix="$WORK/macos-$arch"
  local flags="-arch $arch -mmacosx-version-min=$MIN_MAC"
  if [ "$arch" = "arm64" ]; then x264_host=aarch64-apple-darwin; else x264_host=x86_64-apple-darwin; fi
  rm -rf "$prefix"; mkdir -p "$prefix"
  ffmpeg_common_flags

  if [ "$WITH_X264" = "1" ]; then
    rm -rf "$WORK/x264-build-macos-$arch"; mkdir -p "$WORK/x264-build-macos-$arch"
    ( cd "$WORK/x264-build-macos-$arch"
      export CC="clang $flags"
      export AS="clang $flags"
      "$X264_SRC/configure" --prefix="$prefix" --host="$x264_host" \
        --enable-static --enable-pic --disable-cli --disable-opencl
      make -j"$JOBS" install )
    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
    FF_FLAGS+=(--pkg-config-flags=--static)
  fi

  rm -rf "$WORK/ffmpeg-build-macos-$arch"; mkdir -p "$WORK/ffmpeg-build-macos-$arch"
  ( cd "$WORK/ffmpeg-build-macos-$arch"
    "$FFMPEG_SRC/configure" \
      --prefix="$prefix" "${FF_FLAGS[@]}" \
      --enable-cross-compile --target-os=darwin --arch="$arch" \
      --cc="clang $flags" --x86asmexe=nasm \
      --enable-videotoolbox --enable-encoder=h264_videotoolbox,hevc_videotoolbox \
      --extra-cflags="-O3 -I$prefix/include" --extra-ldflags="$flags -L$prefix/lib"
    make -j"$JOBS"
    make install )
}

build_arch arm64
build_arch x86_64

mkdir -p "$OUT/lib/macos-universal" "$OUT/include"
libs=(avformat avcodec avfilter swscale swresample avutil)
if [ "$WITH_X264" = "1" ]; then libs+=(x264); fi
for l in "${libs[@]}"; do
  lipo -create "$WORK/macos-arm64/lib/lib$l.a" "$WORK/macos-x86_64/lib/lib$l.a" \
       -output "$OUT/lib/macos-universal/lib$l.a"
done
for d in libavcodec libavformat libavutil libavfilter libswscale libswresample; do
  cp -R "$WORK/macos-arm64/include/$d" "$OUT/include/"
done
echo "macOS done -> $OUT/lib/macos-universal"
