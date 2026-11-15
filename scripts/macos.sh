
#!/usr/bin/env bash
#
# White Bot - macOS Universal FFmpeg builder
#
# Builds:
#   arm64
#   x86_64
#
# Merges static libraries using lipo.
#
# Requirements:
#   clang, make, nasm, pkg-config, lipo
#
# Environment:
#   MIN_MAC=11.0
#   WITH_X264=0|1

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

MIN_MAC="${MIN_MAC:-11.0}"
WITH_X264="${WITH_X264:-0}"

# --------------------------------------------------
# Toolchain
# --------------------------------------------------

require_tool() {
    local tool="$1"

    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: Required tool '$tool' was not found in PATH."
        exit 1
    fi
}

for tool in clang make nasm pkg-config lipo; do
    require_tool "$tool"
done

NASM="$(command -v nasm)"
LIPO="$(xcrun --find lipo)"

export PATH="$(dirname "$NASM"):$PATH"

echo "======================================"
echo "White Bot - macOS Universal Build"
echo "======================================"

echo "macOS:"
sw_vers

echo
echo "Clang:"
clang --version

echo
echo "NASM:"
echo "Path: $NASM"
nasm -v

echo
echo "pkg-config:"
pkg-config --version

echo
echo "Minimum macOS: $MIN_MAC"
echo "x264 enabled: $WITH_X264"

# --------------------------------------------------
# Fetch sources
# --------------------------------------------------

fetch_ffmpeg

if [ "$WITH_X264" = "1" ]; then
    fetch_x264
fi

# --------------------------------------------------
# Build one architecture
# --------------------------------------------------

build_arch() {
    local arch="$1"
    local x264_host
    local prefix="$WORK/macos-$arch"
    local ffmpeg_build="$WORK/ffmpeg-build-macos-$arch"
    local flags="-arch $arch -mmacosx-version-min=$MIN_MAC"

    case "$arch" in
        arm64)
            x264_host="aarch64-apple-darwin"
            ;;
        x86_64)
            x264_host="x86_64-apple-darwin"
            ;;
        *)
            echo "ERROR: Unsupported architecture: $arch"
            return 1
            ;;
    esac

    echo
    echo "======================================"
    echo "Building architecture: $arch"
    echo "======================================"

    rm -rf "$prefix"
    mkdir -p "$prefix"

    # Reset FFmpeg configuration flags.
    ffmpeg_common_flags

    # --------------------------------------------------
    # Build x264
    # --------------------------------------------------

    if [ "$WITH_X264" = "1" ]; then
        local x264_build="$WORK/x264-build-macos-$arch"

        rm -rf "$x264_build"
        mkdir -p "$x264_build"

        echo
        echo "======================================"
        echo "Building x264 for $arch"
        echo "======================================"

        echo "NASM executable: $NASM"
        "$NASM" -v

        (
            cd "$x264_build"

            export CC="clang $flags"
            export AS="nasm"
            export NASM

            "$X264_SRC/configure" \
                --prefix="$prefix" \
                --host="$x264_host" \
                --nasm="$NASM" \
                --enable-static \
                --enable-pic \
                --disable-cli \
                --disable-opencl

            make -j"$JOBS"
            make install
        )

        export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"

        FF_FLAGS+=(--pkg-config-flags=--static)
    fi

    # --------------------------------------------------
    # Build FFmpeg
    # --------------------------------------------------

    rm -rf "$ffmpeg_build"
    mkdir -p "$ffmpeg_build"

    echo
    echo "Configuring FFmpeg for $arch..."

    (
        cd "$ffmpeg_build"

        "$FFMPEG_SRC/configure" \
            --prefix="$prefix" \
            "${FF_FLAGS[@]}" \
            --enable-cross-compile \
            --target-os=darwin \
            --arch="$arch" \
            --cc="clang $flags" \
            --x86asmexe="$NASM" \
            --enable-videotoolbox \
            --enable-encoder=h264_videotoolbox,hevc_videotoolbox \
            --extra-cflags="-O3 -I$prefix/include" \
            --extra-ldflags="$flags -L$prefix/lib"

        echo "Compiling FFmpeg for $arch..."

        make -j"$JOBS"
        make install
    )

    echo "FFmpeg build completed for $arch."
}

# --------------------------------------------------
# Build architectures
# --------------------------------------------------

build_arch arm64
build_arch x86_64

# --------------------------------------------------
# Create Universal libraries
# --------------------------------------------------

echo
echo "======================================"
echo "Creating macOS Universal libraries"
echo "======================================"

UNIVERSAL_LIB="$OUT/lib/macos-universal"

mkdir -p "$UNIVERSAL_LIB" "$OUT/include"

libs=(
    avformat
    avcodec
    avfilter
    swscale
    swresample
    avutil
)

if [ "$WITH_X264" = "1" ]; then
    libs+=(x264)
fi

for lib in "${libs[@]}"; do
    ARM64_LIB="$WORK/macos-arm64/lib/lib${lib}.a"
    X86_LIB="$WORK/macos-x86_64/lib/lib${lib}.a"
    OUTPUT_LIB="$UNIVERSAL_LIB/lib${lib}.a"

    if [ ! -f "$ARM64_LIB" ]; then
        echo "ERROR: Missing arm64 library: $ARM64_LIB"
        exit 1
    fi

    if [ ! -f "$X86_LIB" ]; then
        echo "ERROR: Missing x86_64 library: $X86_LIB"
        exit 1
    fi

    echo "Merging lib${lib}.a..."

    "$LIPO" -create \
        "$ARM64_LIB" \
        "$X86_LIB" \
        -output "$OUTPUT_LIB"

    "$LIPO" -verify_arch arm64 x86_64 "$OUTPUT_LIB"
done

# --------------------------------------------------
# Copy FFmpeg headers
# --------------------------------------------------

echo
echo "Copying FFmpeg headers..."

for dir in \
    libavcodec \
    libavformat \
    libavutil \
    libavfilter \
    libswscale \
    libswresample
do
    HEADER_DIR="$WORK/macos-arm64/include/$dir"

    if [ ! -d "$HEADER_DIR" ]; then
        echo "ERROR: Missing FFmpeg header directory: $HEADER_DIR"
        exit 1
    fi

    rm -rf "$OUT/include/$dir"
    cp -R "$HEADER_DIR" "$OUT/include/"
done

# --------------------------------------------------
# Build information
# --------------------------------------------------

cat > "$OUT/BUILD_INFO.txt" <<EOF
Platform: macOS Universal
Architectures: arm64, x86_64
Minimum macOS: $MIN_MAC
FFmpeg version: ${FFMPEG_VERSION:-unknown}
x264 enabled: $WITH_X264
NASM: $(nasm -v)
EOF

# --------------------------------------------------
# Finished
# --------------------------------------------------

echo
echo "======================================"
echo "macOS Universal build completed!"
echo "======================================"

echo "Libraries: $UNIVERSAL_LIB"
echo "Headers:   $OUT/include"
