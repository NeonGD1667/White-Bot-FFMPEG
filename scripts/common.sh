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

# The files that are executable in upstream ffmpeg. A fork uploaded through the GitHub web UI loses the
# +x bit (git mode 100644), and then "$FFMPEG_SRC/configure" fails with "Permission denied" (exit 126) on
# Linux/macOS; ffbuild/*.sh and compat/windows/* are called directly by configure and the makefiles too.
# Permanent fix in the fork: git update-index --chmod=+x <these files>; git commit; git push.
ffmpeg_fix_exec_bits() {
  local dir="$1" f
  for f in \
  compat/solaris/make_sunver.pl \
  compat/windows/makedef \
  compat/windows/mslink \
  compat/windows/mswindres \
  configure \
  doc/doxy-wrapper.sh \
  doc/texi2pod.pl \
  doc/texidep.pl \
  ffbuild/libversion.sh \
  ffbuild/pkgconfig_generate.sh \
  ffbuild/version.sh \
  tests/copycooker.sh \
  tests/fate-run.sh \
  tests/fate.sh \
  tests/fate/source-check.sh \
  tools/bisect-create \
  tools/check_arm_indent.sh \
  tools/clean-diff \
  tools/compare-cvelists.sh \
  tools/dvd2concat \
  tools/gen-rc \
  tools/general_assembly.pl \
  tools/indent_arm_assembly.pl \
  tools/loudnorm.rb \
  tools/make_chlayout_test \
  tools/merge-all-source-plugins \
  tools/missing_codec_desc \
  tools/murge \
  tools/normalize.py \
  tools/patcheck \
  tools/plotframes \
  tools/source2c \
  tools/target_dec_fate.sh \
  tools/unwrap-diff \
  tools/zmqshell.py
  do
    if [ -f "$dir/$f" ]; then chmod +x "$dir/$f"; fi
  done
}

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
    ffmpeg_fix_exec_bits "$FFMPEG_SRC"
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

# --- x264 helpers (used by macos.sh and windows.sh) -------------------------------------------

# Runs an x264 ./configure command (the whole command line is the argument list). x264 prints only
# the failed feature check ("no NEON support ...", "Minimum version is nasm-2.13"), so on failure the
# real reason - the failing compiler/assembler command - is dumped from config.log.
run_x264_configure() {
  if ! "$@"; then
    echo "error: x264 configure failed; config.log follows" >&2
    if [ -f config.log ]; then
      echo "::group::x264 config.log"
      cat config.log
      echo "::endgroup::"
    fi
    return 1
  fi
}

# Runs make with its output kept in a log file (the workflow uploads work/**/*.log when a job fails,
# configure's config.log does not contain compiler errors). On failure the tail is printed again.
# run_make <log file> <make arguments...>
run_make() {
  local log="$1"
  shift
  if ! ( make "$@" 2>&1 | tee "$log" ); then
    echo "error: make $* failed, last lines of $log:" >&2
    tail -n 60 "$log" >&2
    return 1
  fi
}

# Fails when x264's configure silently ended up WITHOUT assembly (it would then build, but slowly).
# x264_require_asm <HAVE_AARCH64 | HAVE_MMX>   (run in the x264 build directory, after configure)
x264_require_asm() {
  if ! grep -q "^#define $1 1" config.h; then
    echo "error: x264 was configured without assembly ($1 missing in config.h)" >&2
    grep -E '^(SYS_ARCH|AS|ASFLAGS|CC|CFLAGS)=' config.mak >&2 || true
    return 1
  fi
}

# Copies the static libs of one build prefix to out/lib/<target>/ and the headers to out/include/.
# collect_libs <prefix> <target> [extension, default a]
collect_libs() {
  local prefix="$1" target="$2" ext="${3:-a}" l d
  mkdir -p "$OUT/lib/$target" "$OUT/include"
  for l in avformat avcodec avfilter swscale swresample avutil; do
    # gcc/clang toolchains install lib<name>.a; ffmpeg's MSVC targets (win32/win64) set LIBSUF=.lib
    # and install lib<name>.lib. Accept either, whatever extension the package should have.
    if [ -f "$prefix/lib/lib$l.$ext" ]; then
      cp "$prefix/lib/lib$l.$ext" "$OUT/lib/$target/lib$l.$ext"
    else
      cp "$prefix/lib/lib$l.a" "$OUT/lib/$target/lib$l.$ext"
    fi
  done
  if [ "$WITH_X264" = "1" ]; then
    cp "$prefix/lib/libx264.$ext" "$OUT/lib/$target/" 2>/dev/null || cp "$prefix/lib/libx264.a" "$OUT/lib/$target/libx264.$ext"
  fi
  for d in libavcodec libavformat libavutil libavfilter libswscale libswresample; do
    cp -R "$prefix/include/$d" "$OUT/include/"
  done
}
