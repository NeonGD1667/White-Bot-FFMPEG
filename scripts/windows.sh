#!/usr/bin/env bash
# Usage: scripts/windows.sh
# Run in an MSYS2 shell that already has the MSVC x64 environment (cl, lib, link on PATH),
# e.g. with ilammy/msvc-dev-cmd + msys2/setup-msys2 (path-type: inherit). Needs make, nasm,
# pkgconf, git, curl, tar, xz, diffutils.
# MSYS2's /usr/bin/link.exe shadows MSVC's link.exe, so the workflow renames it first.
# Static libs are built for the MSVC ABI with the dynamic CRT (/MD), matching White Bot.
source "$(dirname "$0")/common.sh"

WITH_WIN_HW="${WITH_WIN_HW:-1}"   # 1 = NVENC (nv-codec-headers) + AMD AMF encoders
PREFIX="$WORK/windows-x64"
rm -rf "$PREFIX"; mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include"

fetch_ffmpeg
ffmpeg_common_flags

# Both are header-only (the GPU driver is loaded at runtime), so they are fine for an LGPL build.
if [ "$WITH_WIN_HW" = "1" ]; then
  git clone --depth 1 https://github.com/FFmpeg/nv-codec-headers.git "$WORK/nv-codec-headers"
  make -C "$WORK/nv-codec-headers" install PREFIX="$PREFIX"

  git clone --depth 1 https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git "$WORK/AMF"
  mkdir -p "$PREFIX/include/AMF"
  cp -R "$WORK/AMF/amf/public/include/." "$PREFIX/include/AMF/"

  FF_FLAGS+=(--enable-ffnvcodec --enable-nvenc --enable-amf
             --enable-encoder=h264_nvenc,hevc_nvenc,h264_amf,hevc_amf)
fi

if [ "$WITH_X264" = "1" ]; then
  fetch_x264
  rm -rf "$WORK/x264-build-win"; mkdir -p "$WORK/x264-build-win"
  ( cd "$WORK/x264-build-win"
    CC=cl "$X264_SRC/configure" --prefix="$PREFIX" --enable-static --disable-cli --disable-opencl \
      --extra-cflags=-MD
    make -j"$JOBS" install
    # ffmpeg's MSVC pkg-config check looks for x264.lib
    cp "$PREFIX/lib/libx264.lib" "$PREFIX/lib/x264.lib" )
  FF_FLAGS+=(--pkg-config-flags=--static)
fi

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

rm -rf "$WORK/ffmpeg-build-win"; mkdir -p "$WORK/ffmpeg-build-win"
cd "$WORK/ffmpeg-build-win"
"$FFMPEG_SRC/configure" \
  --prefix="$PREFIX" "${FF_FLAGS[@]}" \
  --toolchain=msvc --target-os=win64 --arch=x86_64 \
  --extra-cflags="-MD -I$PREFIX/include" --extra-ldflags="-LIBPATH:$PREFIX/lib"
make -j"$JOBS"
make install

# The msvc toolchain names the archives lib<name>.a; White Bot looks for lib<name>.lib.
collect_libs "$PREFIX" windows-x64 lib
echo "Windows done -> $OUT/lib/windows-x64"
