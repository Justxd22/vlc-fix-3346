#!/usr/bin/env bash
#
# PR A: build VLC-Android (arm64-v8a, VLC 4 / master line) with fontconfig
# ENABLED, so libass regains codepoint-coverage fallback. Two coupled edits:
#
#   1. libvlcjni build-libvlc.sh : drop `--disable-fontconfig` from the contrib
#      bootstrap, so the fontconfig contrib actually gets built.
#   2. vlc contrib/src/ass/rules.mak : flip the Android branch WITH_FONTCONFIG
#      0 -> 1, so libass itself is compiled against fontconfig.
#
# Flow: `--init` fetches libvlcjni + vlc then exits; we edit;
# `-b` rebuilds while leaving our custom sources untouched. `-vlc4` selects the
# master line our edit anchors come from.
#
# Runs in registry.videolan.org/vlc-debian-android:*. Build state under $WORK so
# CI can cache contrib/ccache/gradle.
#
# NOTE: a fontconfig-enabled libass also needs a runtime config pointing at
# /system/fonts (fonts.conf + FONTCONFIG_PATH/XDG_CACHE_HOME). See README.
set -euo pipefail

ABI="${ABI:-arm64-v8a}"
WORK="${WORK:-$PWD/work}"
export CCACHE_DIR="${CCACHE_DIR:-$PWD/.ccache}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$PWD/.gradle}"

VLC_ANDROID_URL="https://code.videolan.org/videolan/vlc-android.git"
COMMON="-vlc4 -a $ABI"

# get-vlc.sh applies VLC patches with `git am`, which needs a committer identity;
# and as root the checkout dirs look "dubiously owned" to git. Settle both.
git config --global user.email "ci@vlc.local" 2>/dev/null || true
git config --global user.name  "vlc ci"       2>/dev/null || true
git config --global --add safe.directory '*'  2>/dev/null || true

echo "==> PR A (fontconfig) | ABI=$ABI WORK=$WORK"
mkdir -p "$WORK" "$CCACHE_DIR" "$GRADLE_USER_HOME"; cd "$WORK"

# 1. vlc-android (orchestrator)
[ -d vlc-android ] || git clone "$VLC_ANDROID_URL"
cd vlc-android
VA_ROOT="$PWD"

# 2. Fetch-only: clones libvlcjni + vlc (+ gradle), then exits (GRADLE_SETUP).
echo "==> fetching sources (--init)"
bash buildsystem/compile.sh --init $COMMON

LIBVLCJNI="$VA_ROOT/libvlcjni"
BUILD_LIBVLC="$LIBVLCJNI/buildsystem/build-libvlc.sh"
ASS_RULES="$LIBVLCJNI/vlc/contrib/src/ass/rules.mak"
[ -f "$BUILD_LIBVLC" ] || { echo "!! $BUILD_LIBVLC not found after --init"; exit 2; }
[ -f "$ASS_RULES" ]    || { echo "!! $ASS_RULES not found after --init"; exit 2; }

# 3a. drop --disable-fontconfig from the contrib bootstrap args
python3 - "$BUILD_LIBVLC" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
new = re.sub(r'^[ \t]*--disable-fontconfig[ \t]*\\\n', '', s, count=1, flags=re.M)
open(p, "w").write(new)
print("build-libvlc.sh:", "--disable-fontconfig removed" if new != s else "already enabled")
PY

# 3b. libass contrib -> fontconfig on Android
python3 - "$ASS_RULES" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old, new = "ifdef HAVE_ANDROID\nWITH_FONTCONFIG = 0", "ifdef HAVE_ANDROID\nWITH_FONTCONFIG = 1"
if old in s:
    open(p, "w").write(s.replace(old, new, 1)); print("ass/rules.mak: WITH_FONTCONFIG=1 (android)")
elif new in s:
    print("ass/rules.mak: already enabled")
else:
    sys.exit("!! ass/rules.mak android anchor not found")
PY

# Force a rebuild of the affected contrib packages if a prior tree was cached.
find "$LIBVLCJNI/vlc/contrib" -maxdepth 2 \( -name '.ass' -o -name '.fontconfig' \) -delete 2>/dev/null || true
find "$LIBVLCJNI/vlc/contrib" -maxdepth 2 -type d -name 'ass-*' -exec rm -rf {} + 2>/dev/null || true

# 4. Full build with our custom sources (-b leaves vlc/libvlcjni untouched).
echo "==> Building (contrib -> libvlc -> jni -> app) ..."
bash buildsystem/compile.sh -b $COMMON

echo "==> APKs:"
find "$VA_ROOT" -name '*.apk' -path '*outputs*' -printf '%p\n'
