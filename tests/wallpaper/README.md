# Wallpaper regression and lock-screen support

Version 1.0.7+8 gives home and lock their own live playlist, media directory,
crop transforms and item duration. PlaylistWallpaperService reads the legacy
home manifest; LockPlaylistWallpaperService reads wallpaper_live_lock.json.
The Android picker receives a different component for each destination, so its
preview displays the selected playlist. Applying one tab never republishes the
other tab's data. Old static worker jobs skip destinations switched to live.

The app cannot silently choose the destination in Android's wallpaper picker.
Choose Home for the home playlist and Lock for the lock playlist. Independent
lock live wallpaper requires support in the device's picker (Android 14+
provides standard support). If only Both is offered, choosing it changes both
screens to that component's playlist; it does not provide two independent lists.

## Automated verification

The test app compiles the production playback, renderer, store and service
sources, with the same service-registration script as the release app.
It exercises real MediaPlayer, SurfaceViews and PixelCopy, not mocked pixels.

Run `python3 tests/wallpaper/prepare.py` with FFmpeg installed, then
`gradle -p tests/wallpaper assembleDebug assembleDebugAndroidTest` and
`bash tests/wallpaper/run_emulator_tests.sh` with an Android 14 emulator connected.

Both workflows have automatic commit/PR triggers disabled. Manually run
Build APK once after finalizing changes; its reusable Android test job runs
first, followed by Flutter tests and the APK build in the same workflow run.
There is no AAB or Release publication.

Coverage includes mixed media, crop/loop/pause/resume, rotated video, GIF frames,
bad-file recovery, simultaneous engines, separate home/lock reapply and rollback,
lock-only rotation, legacy-worker protection and picker service registration.
Flutter tests cover menus, lock-video crop persistence and independent intervals.
Instrumentation output and screenshots are uploaded for review.

## Phone acceptance

1. Add a video through the single-item and multi-select Lock playlist actions.
   Both and Home actions must remain available for the same video.
2. Open Lock, crop a video to a recognizable corner, save and reopen. Verify
   framing is restored while the Home copy retains its own framing.
3. Add a GIF and still image to Lock; set its duration to 10 seconds. Apply Lock
   and choose Lock in the system picker. Video/GIF must move, loop and advance.
4. Set a different Home playlist and duration. Apply Home, choose Home in the
   system picker and lock/unlock repeatedly. Each screen must retain its list.
5. Reapply the Lock list with a new crop or new video. Home must remain unchanged.
6. Test a single video from Set wallpaper with Lock selected; confirm Lock in the
   system picker. The stored playlist itself must not be replaced.
7. Open/close preview, turn screen off/on and return from another app. Playback
   must recover. On screen-off it should not continue decoding.
8. Test a missing source and a corrupt clip. Missing source must leave the last
   applied playlist intact; corrupt playback skips to another item or shows a
   readable error. A later valid reapply must recover.
9. With an old static lock rotation previously scheduled, apply lock video and
   wait past the old interval. The old job must not overwrite the video wallpaper.
10. On a picker without Lock-only support, verify the app explains that choosing
    Both changes both screens. Do not report independent lock support there.

These tests do not replace manufacturer-specific picker testing or establish
support for every codec/HDR format.
