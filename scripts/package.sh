#!/usr/bin/env bash
# Usage: scripts/package.sh <dir with merged include/ + lib/> <output dir>
# Writes white-bot-ffmpeg-<version>-r<revision>[-gpl].tar.gz (+ .sha256) with include/ and lib/
# at the archive root, the layout White Bot's CMake expects for -DWB_FFMPEG_URL / -DWB_FFMPEG_DIR.
set -euo pipefail

SRC="${1:?merged dir}"
DEST="${2:?output dir}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.2}"
REVISION="${REVISION:-1}"
WITH_X264="${WITH_X264:-0}"

name="white-bot-ffmpeg-${FFMPEG_VERSION}-r${REVISION}"
[ "$WITH_X264" = "1" ] && name="$name-gpl"

mkdir -p "$DEST"
cat > "$SRC/BUILD_INFO.txt" <<INFO
ffmpeg:   $FFMPEG_VERSION
source:   $([ -n "${FFMPEG_GIT_URL:-}" ] && echo "${FFMPEG_GIT_URL} @ ${FFMPEG_GIT_REF:-master}" || echo "ffmpeg.org release tarball")
x264:     $([ "$WITH_X264" = "1" ] && echo "yes (GPL build)" || echo "no (LGPL build)")
targets:  $(ls "$SRC/lib" | tr '\n' ' ')
built:    $(date -u +%Y-%m-%dT%H:%M:%SZ)
commit:   ${GITHUB_SHA:-local}
INFO

tar -czf "$DEST/$name.tar.gz" -C "$SRC" include lib BUILD_INFO.txt
( cd "$DEST" && { sha256sum "$name.tar.gz" 2>/dev/null || shasum -a 256 "$name.tar.gz"; } > "$name.tar.gz.sha256" )
echo "$DEST/$name.tar.gz"
