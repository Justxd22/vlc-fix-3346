# vlc-android #3346 fix — non-Latin ASS/SSA subtitles render instead of tofu

Thai, Arabic, Hebrew and Devanagari (and other non-Latin scripts) in `.ass`/`.ssa`
subtitles render as empty boxes on VLC for Android. Root cause: those subtitles go
through **libass**, which on Android is built **without fontconfig** and falls back
to a single hardcoded font (`NotoSansCJK`) that lacks those scripts. **Verified
fixed on-device** (Android 14): Thai/Arabic/Hebrew all render.

## The fix — three edits (applied in `Dockerfile`)

1. **libvlcjni `build-libvlc.sh`** — drop `--disable-fontconfig` so the fontconfig
   contrib is built.
2. **vlc `contrib/src/ass/rules.mak`** — Android `WITH_FONTCONFIG 0 → 1` so libass
   is linked against fontconfig.
3. **vlc `modules/codec/libass.c`** — Android ships no default `fonts.conf`, so the
   fontconfig provider would load zero fonts. Generate a minimal one at runtime
   (pointing at `/system/fonts`, written to the app's `TMPDIR`) and pass its path
   to `ass_set_fonts()` instead of `NULL`.

## Build

```bash
docker build -t vlc3346 .
docker run --rm -v "$PWD/out:/out" vlc3346
# => check current dir you should have ./out/*.apk
```
