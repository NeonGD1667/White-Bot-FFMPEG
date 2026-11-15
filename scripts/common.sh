#!/usr/bin/env bash
# Shared settings and helpers for every target script. Source it, do not run it.
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.2}"   # must match the headers White Bot is compiled against
WITH_X264="${WITH_X264:-0}"                 # 1 = also build libx264 (GPL -> the package is GPL)
X264_BRANCH="${X264_BRANCH:-stable}"
FULL="${FULL:-0}"                           # 1 = keep every ffmpeg component (bigger libs)
# Build ffmpeg from a git repo (your fork) instead of the release tarball:
#   FFMPEG_GIT_URL=https://github.com/<you>/FFmpeg  FFMPEG_GIT_REF=<branch | tag | commit sha>
# FFMPEG_VERSION is then only a label (file name / BUILD_INFO), e.g. 8.1.2-fork.
FFMPEG_GIT_URL="${FFMPEG_GIT_URL:-}"
FFMPEG_GIT_REF="${FFMPEG_GIT_REF:-master}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$ROOT/work}"
OUT="${OUT:-$ROOT/out}"                     # out/include + out/lib/<target>/
JOBS="${JOBS:-$( (nproc || sysctl -n hw.ncpu || echo 4) 2>/dev/null )}"

mkdir -p "$WORK" "$OUT"

fetch_ffmpeg() {
  if [ -n "$FFMPEG_GIT_URL" ]; then
    FFMPEG_SRC="$WORK/ffmpeg-git"
    if [ ! -d "$FFMPEG_SRC/.git" ]; then
      mkdir -p "$FFMPEG_SRC"
      git -C "$FFMPEG_SRC" init -q
      git -C "$FFMPEG_SRC" remote add origin "$FFMPEG_GIT_URL"
      git -C "$FFMPEG_SRC" fetch -q --depth 1 origin "$FFMPEG_GIT_REF"
      git -C "$FFMPEG_SRC" checkout -q FETCH_HEAD
    fi
    echo "ffmpeg source: $FFMPEG_GIT_URL @ $FFMPEG_GIT_REF ($(git -C "$FFMPEG_SRC" rev-parse --short HEAD))"
    return
  fi
  FFMPEG_SRC="$WORK/ffmpeg-$FFMPEG_VERSION"
  if [ ! -d "$FFMPEG_SRC" ]; then
    curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$WORK/ffmpeg.tar.xz"
    tar -xf "$WORK/ffmpeg.tar.xz" -C "$WORK"
  fi
}

fetch_x264() {
  X264_SRC="$WORK/x264"
  if [ ! -d "$X264_SRC" ]; then
    git clone --depth 1 --branch "$X264_BRANCH" https://code.videolan.org/videolan/x264.git "$X264_SRC"
  fi
}

# Flags every target shares. Only what the White Bot recorder / audio mixer use is enabled
# (FULL=1 keeps all components). Hardware encoders are added by each target script.
# --disable-autodetect: nothing is linked implicitly, every dependency is listed explicitly.
ffmpeg_common_flags() {
  FF_FLAGS=(
    --disable-programs --disable-doc --disable-debug
    --disable-avdevice --disable-network --disable-autodetect
    --enable-static --disable-shared --enable-pic
  )
  if [ "$FULL" != "1" ]; then
    FF_FLAGS+=(
      --disable-everything
      --enable-protocol=file
      --enable-demuxer=mov,mp3,ogg,wav,flac,aac,matroska
      --enable-muxer=mp4,mov,matroska,webm
      --enable-parser=h264,hevc,aac,mpegaudio,vorbis,flac,opus
      --enable-decoder=aac,mp3,mp3float,vorbis,flac,opus,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8
      --enable-encoder=aac,mpeg4,pcm_s16le
      --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata
      --enable-filter=colorspace,vflip,format,scale,null,aformat,aresample,anull
    )
  fi
  if [ "$WITH_X264" = "1" ]; then
    FF_FLAGS+=(--enable-gpl --enable-libx264 --enable-encoder=libx264)
  fi
}

# Copies the static libs of one build prefix to out/lib/<target>/ and the headers to out/include/.
# collect_libs <prefix> <target> [extension, default a]
collect_libs() {
  local prefix="$1" target="$2" ext="${3:-a}" l d
  mkdir -p "$OUT/lib/$target" "$OUT/include"
  for l in avformat avcodec avfilter swscale swresample avutil; do
    cp "$prefix/lib/lib$l.a" "$OUT/lib/$target/lib$l.$ext"
  done
  if [ "$WITH_X264" = "1" ]; then
    cp "$prefix/lib/libx264.$ext" "$OUT/lib/$target/" 2>/dev/null || cp "$prefix/lib/libx264.a" "$OUT/lib/$target/libx264.$ext"
  fi
  for d in libavcodec libavformat libavutil libavfilter libswscale libswresample; do
    cp -R "$prefix/include/$d" "$OUT/include/"
  done
}
