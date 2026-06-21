# syntax=docker/dockerfile:1
# vlc-android #3346 fix
#
# Local:
#   docker build -t vlc3346 .
#   docker run --rm -v "$PWD/out:/out" vlc3346
#   => ./out/*.apk
#
FROM registry.videolan.org/vlc-debian-android:20260611083443
USER root

ENV WORK=/work OUT=/out CCACHE_DIR=/ccache GRADLE_USER_HOME=/gradle

COPY <<'SCRIPT' /build.sh
#!/usr/bin/env bash
#
# Build VLC-Android (arm64-v8a, VLC 4 / master) with the #3346 fix: non-Latin
# (Thai/Arabic/Hebrew/Devanagari) ASS/SSA subtitles render instead of tofu.
# Three edits, applied to freshly-fetched sources:
#   1. libvlcjni build-libvlc.sh : drop `--disable-fontconfig` (build fontconfig).
#   2. vlc contrib/src/ass/rules.mak : Android WITH_FONTCONFIG 0 -> 1 (link it).
#   3. vlc modules/codec/libass.c : write a minimal fonts.conf at runtime and pass
#      it to ass_set_fonts() (Android has no default config). Verified on-device.
# `--init` fetches sources then exits; we edit; `-b -r` builds a signed *release*
# APK. `-vlc4` selects the master line the anchors match.
set -euo pipefail

TARGET_ABI="${TARGET_ABI:-arm64-v8a}"
# gmp's configure reads a bare $ABI (valid: 64/32); 
unset ABI || true
WORK="${WORK:-$PWD/work}"
OUT="${OUT:-$PWD/out}"
export CCACHE_DIR="${CCACHE_DIR:-$PWD/.ccache}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$PWD/.gradle}"
export HOME="${HOME:-/root}"

VLC_ANDROID_URL="https://code.videolan.org/videolan/vlc-android.git"
COMMON="-vlc4 -a $TARGET_ABI"

# get-vlc.sh applies VLC patches with `git am` (needs an identity); as root the
# checkout dirs look "dubiously owned" to git. Settle both.
git config --global user.email "ci@vlc.local" 2>/dev/null || true
git config --global user.name  "vlc ci"       2>/dev/null || true
git config --global --add safe.directory '*'  2>/dev/null || true

echo "==> #3346 fix build | ABI=$TARGET_ABI WORK=$WORK OUT=$OUT"
mkdir -p "$WORK" "$OUT" "$CCACHE_DIR" "$GRADLE_USER_HOME"; cd "$WORK"

# Release builds need a signing key. compile.sh defaults to the Android debug
# keystore (storepwd "android"); create it if the image lacks one so the release
# APK is self-signed and installable.
KEYSTORE="$HOME/.android/debug.keystore"
if [ ! -f "$KEYSTORE" ]; then
    mkdir -p "$HOME/.android"
    keytool -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android \
        -alias androiddebugkey -dname "CN=Android Debug,O=Android,C=US" \
        -keyalg RSA -keysize 2048 -validity 10000
fi

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

# 3c. runtime config: make VLC write a minimal fonts.conf (-> /system/fonts) and
#     pass it to ass_set_fonts() instead of NULL.
LIBASS_C="$LIBVLCJNI/vlc/modules/codec/libass.c"
[ -f "$LIBASS_C" ] || { echo "!! $LIBASS_C not found"; exit 2; }
python3 - "$LIBASS_C" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
if "psz_fc_conf" in s:
    print("libass.c: already patched"); sys.exit(0)

block = r'''    char *psz_fc_conf = NULL;
#if defined(__ANDROID__)
    /* Android ships no fontconfig config file, so libass's fontconfig provider
     * loads no fonts and non-Latin scripts (Thai/Arabic/Hebrew/Devanagari) fall
     * back to tofu. Write a minimal config pointing at the system font dirs and
     * hand it to ass_set_fonts(). (vlc-android #3346) */
    {
        const char *psz_tmp = getenv( "TMPDIR" );
        if( psz_tmp != NULL
         && asprintf( &psz_fc_conf, "%s/vlc-fonts.conf", psz_tmp ) >= 0 )
        {
            FILE *fc = fopen( psz_fc_conf, "wt" );
            if( fc != NULL )
            {
                fprintf( fc,
                    "<?xml version=\"1.0\"?>\n"
                    "<!DOCTYPE fontconfig SYSTEM \"fonts.dtd\">\n"
                    "<fontconfig>\n"
                    " <dir>/system/fonts</dir>\n"
                    " <dir>/product/fonts</dir>\n"
                    " <dir>/apex/com.android.i18n/etc/fonts</dir>\n"
                    " <cachedir>%s/fontconfig</cachedir>\n"
                    "</fontconfig>\n", psz_tmp );
                fclose( fc );
            }
            else { free( psz_fc_conf ); psz_fc_conf = NULL; }
        }
    }
#endif
'''

a1 = "#ifdef HAVE_FONTCONFIG\n#if defined(_WIN32)"
a2 = "ASS_FONTPROVIDER_AUTODETECT, NULL, 1 );"
a3 = ("#endif\n#else\n    ass_set_fonts( p_renderer, psz_font, psz_family, "
      "ASS_FONTPROVIDER_AUTODETECT, NULL, 0 );")
for a in (a1, a2, a3):
    if a not in s: sys.exit("!! libass.c anchor not found:\n" + a)

s = s.replace(a1, "#ifdef HAVE_FONTCONFIG\n" + block + "#if defined(_WIN32)", 1)
s = s.replace(a2, "ASS_FONTPROVIDER_AUTODETECT, psz_fc_conf, 1 );", 1)
s = s.replace(a3, "#endif\n    free( psz_fc_conf );\n#else\n    ass_set_fonts( "
                  "p_renderer, psz_font, psz_family, "
                  "ASS_FONTPROVIDER_AUTODETECT, NULL, 0 );", 1)
open(p, "w").write(s); print("libass.c: fontconfig config-path patch applied")
PY

# 3d. Non-`dev` variants pull a PREBUILT libvlc from Maven (libvlc-all) — which
#     lacks our fix AND leaks in transitively via :medialibrary, so two
#     libvlc.so collide at native-lib merge. Substitute *every* libvlc-all with
#     the local patched project, across all modules/variants/configurations.
ROOT_GRADLE="$VA_ROOT/build.gradle"
[ -f "$ROOT_GRADLE" ] || { echo "!! $ROOT_GRADLE not found"; exit 2; }
python3 - "$ROOT_GRADLE" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
if "libvlc-all') using project" in s:
    print("root build.gradle: libvlc substitution already present"); sys.exit(0)
# allprojects -> reaches :application:app (where native-lib merge runs) too.
block = """
// #3346: force the locally-built (patched) libvlc everywhere instead of the
// prebuilt Maven libvlc-all (which lacks our fontconfig fix and collides with
// the local libvlc.so during native-lib merge).
allprojects {
    configurations.all {
        resolutionStrategy.dependencySubstitution {
            substitute module('org.videolan.android:libvlc-all') using project(':libvlcjni:libvlc')
        }
    }
}
"""
open(p, "a").write(block); print("root build.gradle: libvlc-all -> local project substitution added")
PY

# A restored cache can carry (a) meson build dirs generated by a DIFFERENT meson
# version -> "incompatible Meson version" build failures, and (b) stale binaries
# that predate our edits. Drop all build *outputs* so contrib/VLC/libvlc rebuild
# cleanly; cached tarballs + ccache + gradle keep this from being fully cold.
rm -rf "$LIBVLCJNI"/vlc/contrib/contrib-android-* \
       "$LIBVLCJNI"/vlc/contrib/*-linux-android \
       "$LIBVLCJNI"/vlc/build-android-* \
       "$LIBVLCJNI"/libvlc/jni/obj "$LIBVLCJNI"/libvlc/jni/libs "$LIBVLCJNI"/.dbg \
       2>/dev/null || true
# Catch any other cross-version meson build dir (e.g. medialibrary's).
find "$WORK" -type d -name meson-info -printf '%h\0' 2>/dev/null | xargs -0 rm -rf 2>/dev/null || true

# 4. Full release build (-b keeps our custom sources; -r => signed Release APK).
# Remove stale APKs first so a failed build can't leave one for us to ship.
find "$VA_ROOT" -path '*outputs*' -name '*.apk' -delete 2>/dev/null || true
echo "==> Building release (contrib -> libvlc -> jni -> app) ..."
set +e
bash buildsystem/compile.sh -b -r $COMMON
BUILD_RC=$?
set -e

# 5. Pick the $TARGET_ABI release APK and sign it.
echo "==> selecting + signing $TARGET_ABI release APK -> $OUT"
APK="$(find "$VA_ROOT" -path '*outputs*' -path '*elease*' -name "*$TARGET_ABI*.apk" \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
if [ -z "$APK" ]; then
    echo "!! no freshly-built $TARGET_ABI release APK (build rc=$BUILD_RC); APKs found:"
    find "$VA_ROOT" -path '*outputs*' -name '*.apk' -printf '   %p\n' 2>/dev/null
    [ "$BUILD_RC" -ne 0 ] && exit "$BUILD_RC"
    exit 1
fi

# zipalign + self-sign with the debug keystore so it installs.
BT="$(ls -d "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/sdk/android-sdk-linux}}"/build-tools/* | sort -V | tail -1)"
DEST="$OUT/$(basename "$APK")"
"$BT/zipalign" -f -p 4 "$APK" "$DEST"
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android \
    --ks-key-alias androiddebugkey --key-pass pass:android "$DEST"
"$BT/apksigner" verify "$DEST"
echo "==> done (signed): $DEST"
SCRIPT

CMD ["bash", "/build.sh"]
