#!/usr/bin/env bash
set -euo pipefail
# Run the already-built instrumentation APK directly so Gradle's test cleanup
# does not uninstall the app (and its screenshots) before evidence is collected.
adb install -r tests/wallpaper/app/build/outputs/apk/debug/app-debug.apk
adb install -r tests/wallpaper/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w -r com.tttas.wallpapertest.test/androidx.test.runner.AndroidJUnitRunner > tests/wallpaper/instrumentation.txt
cat tests/wallpaper/instrumentation.txt
adb logcat -d -s PlaylistWP > tests/wallpaper/playback.log
adb pull /sdcard/Android/data/com.tttas.wallpapertest/files/evidence tests/wallpaper/evidence
# am instrument can exit zero even when JUnit fails, so require its success line.
grep -Eq 'OK \([1-9][0-9]* tests?\)' tests/wallpaper/instrumentation.txt
