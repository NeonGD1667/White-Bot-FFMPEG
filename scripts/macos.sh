
#!/usr/bin/env bash
#
# Usage: scripts/macos.sh
# Builds FFmpeg for macOS arm64 + x86_64,
# then merges static libraries into macOS Universal using lipo.
#
# Requirements:
#   clang, make, lipo, nasm, pkg-config
#
# Environment:
#   MIN_MAC       Minimum macOS deployment target (default: 11.0)
#   WITH_X264     Enable x264 build when set to 1
#
# Output:
#   out/lib/macos-universal/
#   out/include/

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

MIN_MAC="${MIN_MAC:-11.0}"

# --------------------------------------------------
# Toolchain validation
# --------------------------------------------------

require_tool() {
    local tool="$1"

    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: Required tool '$tool' was not found in PATH."
        exit 1
    fi
}

for tool in clang make lipo nasm pkg-config; do
    require_tool "$tool"
done

NASM="$(command -v nasm)"

echo "======================================"
echo "White Bot - macOS FFmpeg Build"
echo "======================================"
echo "Minimum macOS: $MIN_MAC"
echo "NASM: $NASM"
nasm -v
echo
clang --version
echo
pkg-config --version
echo

# --------------------------------------------------
# Fetch sources
# --------------------------------------------------

fetch_ffmpeg

if [ "${WITH_X264:-0}" = "1" ]; then
    fetch_x264
fi

# --------------------------------------------------
# Build one architecture
# --------------------------------------------------

build_arch() {
    local arch="$1"
    local x264_host
    local prefix="$WORK/macos-$arch"
    local build_dir="$WORK/ffmpeg-build-macos-$arch"
    local flags="-arch $arch -mmacosx-version-min=$MIN_MAC"

    case "$arch" in
        arm64)
            x264_host="aarch64-apple-darwin"
            ;;
        x86_64)
            x264_host="x86_64-apple-darwin"
            ;;
        *)
            echo "ERROR: Unsupported macOS architecture: $arch"
            return 1
            ;;
    esac

    echo
    echo "======================================"
    echo "Building architecture: $arch"
    echo "======================================"

    rm -rf "$prefix"
    mkdir -p "$prefix"

    # Reset common FFmpeg configuration flags for this architecture.
    ffmpeg_common_flags

    # --------------------------------------------------
    # Build x264 (optional)
    # --------------------------------------------------

    if [ "${WITH_X264:-0}" = "1" ]; then
        local x264_build_dir="$WORK/x264-build-macos-$arch"

        rm -rf "$x264_build_dir"
        mkdir -p "$x264_build_dir"

        echo "Building x264 for $arch..."

        (
            cd "$x264_build_dir"

            export CC="clang $flags"
            export AS="clang $flags"

            "$X264_SRC/configure" \
                --prefix="$prefix" \
                --host="$x264_host" \
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
    # Configure and build FFmpeg
    # --------------------------------------------------

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    echo "Configuring FFmpeg for $arch..."

    (
        cd "$build_dir"

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
# Build both architectures
# --------------------------------------------------

build_arch arm64
build_arch x86_64

# --------------------------------------------------
# Merge universal static libraries
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

if [ "${WITH_X264:-0}" = "1" ]; then
    libs+=(x264)
fi

for lib in "${libs[@]}"; do
    arm64_lib="$WORK/macos-arm64/lib/lib${lib}.a"
    x86_lib="$WORK/macos-x86_64/lib/lib${lib}.a"
    output_lib="$UNIVERSAL_LIB/lib${lib}.a"

    if [ ! -f "$arm64_lib" ]; then
        echo "ERROR: Missing arm64 library: $arm64_lib"
        exit 1
    fi

    if [ ! -f "$x86_lib" ]; then
        echo "ERROR: Missing x86_64 library: $x86_lib"
        exit 1
    fi

    echo "Merging lib${lib}.a..."

    lipo -create \
        "$arm64_lib" \
        "$x86_lib" \
        -output "$output_lib"

    lipo -verify_arch arm64 x86_64 "$output_lib"
done

# --------------------------------------------------
# Copy headers
# --------------------------------------------------

for dir in \
    libavcodec \
    libavformat \
    libavutil \
    libavfilter \
    libswscale \
    libswresample
do
    if [ ! -d "$WORK/macos-arm64/include/$dir" ]; then
        echo "ERROR: Missing FFmpeg headers: $dir"
        exit 1
    fi

    cp -R "$WORK/macos-arm64/include/$dir" "$OUT/include/"
done

# --------------------------------------------------
# Build information
# --------------------------------------------------

cat > "$OUT/BUILD_INFO.txt" <<EOF
Platform: macOS Universal
Architectures: arm64, x86_64
Minimum macOS: $MIN_MAC
FFmpeg version: ${FFMPEG_VERSION:-unknown}
x264 enabled: ${WITH_X264:-0}
NASM: $(nasm -v)
EOF

echo
echo "======================================"
echo "macOS Universal build completed!"
echo "======================================"
echo "Libraries: $UNIVERSAL_LIB"
echo "Headers:   $OUT/include"
