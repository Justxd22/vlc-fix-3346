#!/usr/bin/env bash
#
# PR A: build VLC-Android (arm64-v8a) with fontconfig ENABLED, so libass regains
# codepoint-coverage fallback (the proven-on-desktop path). Two coupled edits:
#
#   1. libvlcjni build-libvlc.sh : drop `--disable-fontconfig` from the contrib
#      bootstrap, so the fontconfig contrib actually gets built.
#   2. vlc contrib/src/ass/rules.mak : flip the Android branch WITH_FONTCONFIG
#      0 -> 1, so libass itself is compiled against fontconfig.
#
# Designed for the official image registry.videolan.org/vlc-debian-android:*.
# All build state is kept under $WORK (defaults inside the workspace) so CI can
# cache contrib/ccache/gradle between runs.
#
# NOTE: a built-in fontconfig also needs a runtime config pointing at
# /system/fonts. fonts.conf is shipped here; see README for the one-line env
# wiring needed for it to take effect on-device.
set -euo pipefail

ABI="${ABI:-arm64-v8a}"
WORK="${WORK:-$PWD/work}"
export CCACHE_DIR="${CCACHE_DIR:-$PWD/.ccache}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$PWD/.gradle}"

VLC_ANDROID_URL="https://code.videolan.org/videolan/vlc-android.git"

echo "==> PR A (fontconfig) | ABI=$ABI WORK=$WORK CCACHE_DIR=$CCACHE_DIR"
mkdir -p "$WORK" "$CCACHE_DIR" "$GRADLE_USER_HOME"; cd "$WORK"

# 1. Sources
if [ ! -d vlc-android ]; then
    git clone --depth 1 "$VLC_ANDROID_URL"
fi
cd vlc-android

# Fetch libvlcjni + vlc without a full build so we can edit before compiling.
./compile.sh -l -a "$ABI" --fetch-only 2>/dev/null || \
  bash buildsystem/compile.sh -l -a "$ABI" --fetch-only 2>/dev/null || true

BUILD_LIBVLC="$(find "$PWD" -path '*buildsystem/build-libvlc.sh' | head -1)"
[ -z "$BUILD_LIBVLC" ] && { echo "!! build-libvlc.sh not found"; exit 2; }
VLC_SRC="$(dirname "$(find "$PWD" -maxdepth 5 -type f -name 'configure.ac' -path '*vlc*' | head -1)")"
[ -z "$VLC_SRC" ] && { echo "!! VLC core source not found"; exit 2; }
echo "==> build-libvlc.sh: $BUILD_LIBVLC"
echo "==> VLC core source: $VLC_SRC"

# 2. Edit (a): drop --disable-fontconfig from the contrib bootstrap args.
python3 - "$BUILD_LIBVLC" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
new = re.sub(r'^[ \t]*--disable-fontconfig[ \t]*\\\n', '', s, count=1, flags=re.M)
open(p, "w").write(new)
print("build-libvlc.sh: --disable-fontconfig removed" if new != s
      else "build-libvlc.sh: already enabled")
PY

# 3. Edit (b): libass contrib -> fontconfig on Android.
python3 - "$VLC_SRC/contrib/src/ass/rules.mak" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "ifdef HAVE_ANDROID\nWITH_FONTCONFIG = 0"
new = "ifdef HAVE_ANDROID\nWITH_FONTCONFIG = 1"
if old in s:
    open(p, "w").write(s.replace(old, new, 1)); print("ass/rules.mak: WITH_FONTCONFIG=1 (android)")
elif new in s:
    print("ass/rules.mak: already enabled")
else:
    sys.exit("!! ass/rules.mak android anchor not found")
PY

# Force the (now fontconfig-linked) libass + fontconfig contrib to rebuild.
find "$VLC_SRC/contrib" -maxdepth 2 \( -name '.ass' -o -name '.fontconfig' \) -delete 2>/dev/null || true
find "$VLC_SRC/contrib" -maxdepth 2 -type d -name 'ass-*' -exec rm -rf {} + 2>/dev/null || true

# 4. Full build, arm64 debug APK.
echo "==> Building ..."
./compile.sh -b -a "$ABI" || bash buildsystem/compile.sh -b -a "$ABI"

echo "==> APKs:"
find "$PWD" -name '*.apk' -path '*outputs*' -printf '%p\n'
