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

TARGET_ABI="${TARGET_ABI:-arm64-v8a}"
# gmp's configure reads a bare $ABI (valid: 64/32); a leaked ABI=arm64-v8a
# kills the contrib build. Make sure it isn't in the environment.
unset ABI || true
WORK="${WORK:-$PWD/work}"
export CCACHE_DIR="${CCACHE_DIR:-$PWD/.ccache}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$PWD/.gradle}"

VLC_ANDROID_URL="https://code.videolan.org/videolan/vlc-android.git"
COMMON="-vlc4 -a $TARGET_ABI"

# get-vlc.sh applies VLC patches with `git am`, which needs a committer identity;
# and as root the checkout dirs look "dubiously owned" to git. Settle both.
git config --global user.email "ci@vlc.local" 2>/dev/null || true
git config --global user.name  "vlc ci"       2>/dev/null || true
git config --global --add safe.directory '*'  2>/dev/null || true

echo "==> PR A (fontconfig) | ABI=$TARGET_ABI WORK=$WORK"
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

# 3c. runtime config: VLC passes config=NULL to ass_set_fonts, and Android has
#     no default fonts.conf, so the fontconfig provider loads zero fonts. Make
#     VLC write a minimal fonts.conf (pointing at /system/fonts) and pass it.
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

# Force a rebuild of the affected contrib packages if a prior tree was cached.
find "$LIBVLCJNI/vlc/contrib" -maxdepth 2 \( -name '.ass' -o -name '.fontconfig' \) -delete 2>/dev/null || true
find "$LIBVLCJNI/vlc/contrib" -maxdepth 2 -type d -name 'ass-*' -exec rm -rf {} + 2>/dev/null || true

# 4. Full build with our custom sources (-b leaves vlc/libvlcjni untouched).
echo "==> Building (contrib -> libvlc -> jni -> app) ..."
bash buildsystem/compile.sh -b $COMMON

echo "==> APKs:"
find "$VA_ROOT" -name '*.apk' -path '*outputs*' -printf '%p\n'
