# Wallpaper regression

The test app compiles the production WallpaperPlayback, WallpaperRenderer and
WallpaperStore sources. It uses Android MediaPlayer, real SurfaceViews and
PixelCopy; it does not mock decoded frames or rendering.

Run `python3 tests/wallpaper/prepare.py` (requires ffmpeg), then
`gradle -p tests/wallpaper connectedDebugAndroidTest` with Android API 30+ connected.
The GitHub workflow runs this on an API 30 emulator and uploads screenshots and
JUnit reports. This verifies the rendering engine; a phone/system wallpaper
picker still needs the acceptance steps below.

## Phone acceptance for 1.0.6+7

1. Open an MP4, open its wallpaper menu. Verify Set wallpaper, Add to home
   playlist, Playlist and Settings. Lock-only actions explain the image limit.
2. Set wallpaper opens the playing video in the crop frame. Zoom and drag to a
   recognizable corner. Confirm in the Android wallpaper picker. Both its preview
   and the installed home wallpaper must show the same corner, moving and muted.
3. Add still image, GIF, MP4 and WebM to home playlist. Crop the video, save,
   reopen its crop page and verify framing is restored. Apply with 10-second
   interval. All items must appear in order and video must loop if shorter.
4. Open the system preview again, confirm, return home. No black screen after
   either opening or closing preview.
5. Open another app, turn screen off/on and return home. Playback resumes.
6. Apply one rotated portrait video. Its orientation and aspect ratio must match
   the in-app preview.
7. Delete a playlist source before Apply: explain the missing source and preserve
   the old applied playlist. A decoder failure skips to another valid item; when
   all sources fail, show a readable error instead of a blank black wallpaper.
8. Use Settings from both the video menu and playlist. Interval/shuffle values
   must be shared. Existing still-image single wallpaper and lock rotation must
   continue working.

Automated tests do not cover manufacturer-specific wallpaper picker behavior,
all codecs/HDR formats, or power consumption on physical devices.
