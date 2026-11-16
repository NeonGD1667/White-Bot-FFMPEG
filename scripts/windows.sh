#!/usr/bin/env bash
# Usage: scripts/windows.sh
# Run in an MSYS2 shell that already has the MSVC x64 environment (cl, lib, link on PATH),
# e.g. with ilammy/msvc-dev-cmd + msys2/setup-msys2 (path-type: inherit). Needs make, nasm,
# pkgconf, git, curl, tar, xz, diffutils.
# MSYS2's /usr/bin/link.exe shadows MSVC's link.exe, so the workflow renames it first.
# Static libs are built for the MSVC ABI with the dynamic CRT (/MD), matching White Bot.

set -Eeuo pipefail

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

# MSVC (C7757) rejects libavformat/cbs.c when its CBS type table is empty. In ffmpeg 8.1,
# libavformat/cbs.c includes libavcodec/cbs.c with only AV1 and APV left enabled (CBS_AV1 =
# CONFIG_CBS_AV1, CBS_APV = CONFIG_CBS_APV) and the mp4/mov muxer always compiles it. With the
# allow-list build neither is selected, so `static const CodedBitstreamType *const t[] = { };` is
# empty: accepted by gcc/clang as an extension, an error for cl. The AV1 parser selects cbs_av1
# (and nothing else of significance), which makes the table non-empty. This works with the
# unpatched upstream source (release tarball) as well as with the patched fork.
FF_FLAGS+=(--enable-parser=av1)

if [ "$WITH_X264" = "1" ]; then
  fetch_x264
  rm -rf "$WORK/x264-build-win"; mkdir -p "$WORK/x264-build-win"
  ( cd "$WORK/x264-build-win"
    CC=cl run_x264_configure "$X264_SRC/configure" --prefix="$PREFIX" --enable-static --disable-cli --disable-opencl \
      --extra-cflags=-MD
    run_make "$WORK/x264-build-win/make.log" -j"$JOBS" install
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
  --extra-cflags="-MD -I$PREFIX/include" --extra-ldflags="-LIBPATH:$PREFIX/lib" \
  2>&1 | tee "$WORK/ffmpeg-build-win/configure.log"

# Guard for the cbs.c problem above: stop here, with a clear message, instead of after minutes of make.
if ! grep -q '^#define CONFIG_CBS_AV1 1' config.h; then
  echo "error: CONFIG_CBS_AV1 is 0, libavformat/cbs.c would have an empty table and fail with MSVC C7757" >&2
  exit 1
fi

run_make "$WORK/ffmpeg-build-win/make.log" -j"$JOBS"
run_make "$WORK/ffmpeg-build-win/make-install.log" install

# --------------------------------------------------
# Verify libs exist before collecting
# --------------------------------------------------
# ffmpeg's MSVC toolchain sets LIBPREF= (empty), so libs are installed WITHOUT the "lib" prefix:
#   avfilter.lib, avformat.lib, ... (not libavfilter.lib)
# collect_libs in common.sh handles both naming conventions.

echo
echo "======================================"
echo "Verifying Windows libraries..."
echo "======================================"

echo "Contents of $PREFIX/lib/:"
ls -la "$PREFIX/lib/"

for l in avformat avcodec avfilter swscale swresample avutil; do
  if [ -f "$PREFIX/lib/lib$l.lib" ]; then
    echo "  OK (lib prefix): lib$l.lib"
  elif [ -f "$PREFIX/lib/$l.lib" ]; then
    echo "  OK (no prefix):  $l.lib"
  else
    echo "ERROR: cannot find lib for '$l' in $PREFIX/lib/" >&2
    exit 1
  fi
done

# --------------------------------------------------
# Collect output
# --------------------------------------------------

# collect_libs copies either lib<name>.lib or <name>.lib to out/lib/windows-x64/lib<name>.lib
collect_libs "$PREFIX" windows-x64 lib

echo
echo "======================================"
echo "Windows done -> $OUT/lib/windows-x64"
echo "======================================"
ls -lh "$OUT/lib/windows-x64/"
