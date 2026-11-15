# White-Bot-ffmpeg

Builds the static ffmpeg libraries that [White Bot](https://github.com/NeonGD1667/White-Bot) embeds
(replaces the old `eclipse.ffmpeg-api` mod and, optionally, `ffmpeg.exe`).

One package, five targets:

| target (`lib/<target>/`) | built on | hardware encoder |
|---|---|---|
| `arm64-v8a`, `armeabi-v7a` (Android API 24) | ubuntu + NDK | MediaCodec |
| `ios-arm64` (iOS 14+) | macos-14 | VideoToolbox |
| `macos-universal` (arm64 + x86_64, `lipo`) | macos-14 | VideoToolbox |
| `windows-x64` (MSVC ABI, `/MD`) | windows-latest | NVENC, AMD AMF |

Package layout (what White Bot's `CMakeLists.txt` expects):

```
include/libavcodec/... include/libavutil/...   (FFmpeg headers, same version as the libs)
lib/<target>/lib{avformat,avcodec,avfilter,swscale,swresample,avutil}.{a|lib}
lib/<target>/libx264.{a|lib}                   (only in the -gpl package)
BUILD_INFO.txt
```

## Build

GitHub Actions -> *Build ffmpeg libs* -> **Run workflow**:

* `ffmpeg_version` - keep it equal to the headers White Bot was written against (`8.1.2`).
* `ffmpeg_repo` / `ffmpeg_ref` - optional: build ffmpeg from your own fork (git URL + branch, tag or
  commit sha) instead of the ffmpeg.org tarball. `ffmpeg_version` is then only a label for the file
  name, e.g. `8.1.2-fork`. Headers and libs both come from that fork, but White Bot's code
  must still compile against its API (it was written for 8.1.x). Locally:
  `FFMPEG_GIT_URL=https://github.com/<you>/FFmpeg FFMPEG_GIT_REF=my-branch bash scripts/android.sh arm64-v8a`.
* `gpl` - also build `libx264`. **The package (and a White Bot linked with it) is then GPL.**
  Leave off for an LGPL build that encodes with the platform hardware encoders.
* `win_hw` - Windows: build the NVENC and AMF encoders (header-only, no GPL).
* `revision` - the `r<N>` in the file name.
* `release` - publish the `.tar.gz` (+ `.sha256`) as a GitHub release. Pushing a tag `v*` does the same.

Result: `white-bot-ffmpeg-<version>-r<N>[-gpl].tar.gz`.

## Use it in White Bot

```
cmake ... -DWB_FFMPEG_URL=https://github.com/<you>/White-Bot-ffmpeg/releases/download/<tag>/white-bot-ffmpeg-8.1.2-r1.tar.gz
# or extract it to <White-Bot>/ffmpeg, or -DWB_FFMPEG_DIR=<dir>
```

## Build locally

```
FFMPEG_VERSION=8.1.2 WITH_X264=0 bash scripts/android.sh arm64-v8a   # needs ANDROID_NDK_HOME
bash scripts/ios.sh        # macOS + Xcode
bash scripts/macos.sh      # macOS + nasm
bash scripts/windows.sh    # MSYS2 shell with the MSVC x64 environment (see the workflow)
```

Output goes to `out/` (`include/` and `lib/<target>/`); `bash scripts/package.sh <merged dir> dist`
makes the archive.

## What is compiled in

A small allow-list (`scripts/common.sh`): mp4/mov/matroska/webm muxing, the audio decoders and
demuxers the audio mixer needs, the `aac` and `mpeg4` encoders, the `buffer`, `buffersink`,
`colorspace`, `vflip`, `format`, `scale`, `aresample` filters, plus the platform hardware encoders.
Set `FULL=1` to keep every ffmpeg component instead (much bigger libs).

## Known gaps / not verified

* None of these scripts have been run yet; the first CI run will probably need small fixes.
  The riskiest parts are the Windows build (MSVC toolchain, `pkg-config` + NVENC/AMF headers,
  x264 `libx264.lib`) and the x264 cross builds.
* No `libvpx`, `libaom`, `libx265` (the old fork linked them) and no Intel QSV (`h264_qsv`).
  White Bot's "Intel (QSV)" option has no encoder behind it until `libvpl` is added.
* Without `gpl`, the only software video encoder is `mpeg4`.
* FFmpeg itself is LGPL 2.1+ (GPL with `--enable-gpl`); ship its license/notice with White Bot.
