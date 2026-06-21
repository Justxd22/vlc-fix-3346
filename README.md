# fix #3346 by enabling fontconfig on Android

The low-risk fix: re-enable **fontconfig** so libass regains codepoint-coverage
font fallback (`get_fallback`). This is the exact path desktop VLC uses, proven
to render Thai correctly.

## What the build changes (two coupled edits, applied by `build.sh`)

1. `libvlcjni/buildsystem/build-libvlc.sh` — remove `--disable-fontconfig` from
   the contrib bootstrap, so the fontconfig contrib is built.
2. `vlc/contrib/src/ass/rules.mak` — flip the Android branch
   `WITH_FONTCONFIG = 0` → `1`, so libass is compiled against fontconfig
   (`-Dfontconfig=enabled`, pulling in the `DEPS_ass += fontconfig`).

Both are deterministic, anchored edits — see `build.sh`.

## Files

| File | Role |
|---|---|
| `build.sh` | applies the two edits, builds the arm64 debug APK |
| `ci/build-fontconfig.yml` | GitHub Actions: build in the official container, **cache** contrib/ccache/gradle, upload the APK |
| `fonts.conf` | runtime fontconfig config pointing at `/system/fonts` (see caveat) |

## Local

```bash
docker run --rm -v "$PWD:/src" -w /src \
  registry.videolan.org/vlc-debian-android:20260611083443 \
  bash fixA/build.sh
# APK under work/vlc-android/.../outputs/apk/
```
