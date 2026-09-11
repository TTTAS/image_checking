package com.tttas.wallpapertest

import android.graphics.Bitmap
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONArray
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class PlaybackTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private lateinit var scenario: ActivityScenario<SurfaceActivity>
    private lateinit var activity: SurfaceActivity
    private var serial = 0

    @Before fun prepare() {
        for (name in listOf("quadrants.mp4", "rotated.mp4", "motion.gif", "sample.webm")) {
            context.assets.open(name).use { input ->
                File(context.filesDir, name).outputStream().use { input.copyTo(it) }
            }
        }
        val bitmap = Bitmap.createBitmap(160, 120, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.WHITE)
        File(context.filesDir, "still.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    @After fun close() { if (::scenario.isInitialized) scenario.close() }

    private fun item(name: String, zoom: Double = 0.0, fx: Double = .5, fy: Double = .5) =
        JSONObject().put("path", File(context.filesDir, name).absolutePath)
            .put("zoom", zoom).put("focusX", fx).put("focusY", fy)

    private fun manifest(vararg items: JSONObject, seconds: Int = 1) {
        File(context.filesDir, "wallpaper_live.json").writeText(
            JSONObject().put("items", JSONArray(items.toList()))
                .put("seconds", seconds).put("revision", serial++).toString())
    }

    private fun launch() {
        scenario = ActivityScenario.launch(SurfaceActivity::class.java)
        scenario.onActivity { activity = it }
    }

    private fun main(block: () -> Unit) = instrumentation.runOnMainSync(block)

    private fun pixels(): Bitmap {
        var result: Bitmap? = null
        var code = -1
        val latch = CountDownLatch(1)
        main {
            val b = Bitmap.createBitmap(activity.view.width, activity.view.height, Bitmap.Config.ARGB_8888)
            result = b
            PixelCopy.request(activity.view, b, { code = it; latch.countDown() }, Handler(Looper.getMainLooper()))
        }
        check(latch.await(3, TimeUnit.SECONDS)) { "PixelCopy timed out" }
        check(code == PixelCopy.SUCCESS) { "PixelCopy failed: $code" }
        return result!!
    }

    private fun matches(actual: Int, expected: Int) =
        kotlin.math.abs(Color.red(actual) - Color.red(expected)) < 65 &&
        kotlin.math.abs(Color.green(actual) - Color.green(expected)) < 65 &&
        kotlin.math.abs(Color.blue(actual) - Color.blue(expected)) < 65

    private fun awaitPixels(name: String, timeoutMs: Long = 15000, check: (Bitmap) -> Boolean): Bitmap {
        val deadline = System.currentTimeMillis() + timeoutMs
        var latest: Bitmap? = null
        while (System.currentTimeMillis() < deadline) {
            try {
                val b = pixels()
                latest?.recycle()
                latest = b
                if (check(b)) { evidence(name, b); return b }
            } catch (_: IllegalStateException) {}
            Thread.sleep(80)
        }
        latest?.let { evidence("FAILED-$name", it) }
        fail("Expected rendered pixels: $name (see screenshot)")
        error("unreachable")
    }

    private fun evidence(name: String, b: Bitmap) {
        val dir = File(context.getExternalFilesDir(null), "evidence").apply { mkdirs() }
        File(dir, "$name.png").outputStream().use { b.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private fun solid(name: String, color: Int) = awaitPixels(name) {
        matches(it.getPixel(it.width / 2, it.height / 2), color)
    }.recycle()

    @Test fun mixedMediaSwitchesOnTheSameSurface() {
        manifest(item("still.png"), item("quadrants.mp4"), item("motion.gif"), item("sample.webm"))
        launch()
        solid("01-still", Color.WHITE)
        awaitPixels("02-video-quadrants") { b ->
            val scale = minOf(b.width / 320f, b.height / 240f)
            val x = b.width / 2
            val y = b.height / 2
            val dx = (80 * scale).toInt()
            val dy = (60 * scale).toInt()
            matches(b.getPixel(x-dx,y-dy), Color.RED) &&
                matches(b.getPixel(x+dx,y-dy), Color.GREEN) &&
                matches(b.getPixel(x-dx,y+dy), Color.BLUE) &&
                matches(b.getPixel(x+dx,y+dy), Color.YELLOW)
        }.recycle()
        solid("03-gif", Color.MAGENTA)
        solid("04-webm", Color.CYAN)
        solid("05-still-after-video", Color.WHITE)
    }

    @Test fun cropLoopPauseResumeAndSurfaceRecreation() {
        manifest(item("quadrants.mp4", 2.0, .25, .25), seconds = 1)
        launch()
        solid("06-video-crop-red", Color.RED)
        var before = 0
        main { before = activity.playback.renderedFrames }
        Thread.sleep(2400) // Longer than both the playlist interval and the clip.
        main { assertTrue(activity.playback.renderedFrames > before + 5) }
        solid("07-video-still-looping", Color.RED)
        main { activity.playback.setVisible(false); before = activity.playback.renderedFrames }
        Thread.sleep(400)
        main {
            assertFalse(activity.playback.hasPlayer)
            assertEquals(before, activity.playback.renderedFrames)
            activity.playback.setVisible(true)
        }
        solid("08-video-resumed", Color.RED)
        main {
            activity.playback.detach()
            activity.playback.attach(activity.view.holder.surface, activity.view.width, activity.view.height)
        }
        solid("09-video-surface-recreated", Color.RED)
        manifest(item("quadrants.mp4", 2.0, .75, .75), seconds = 1)
        solid("10-new-crop-yellow", Color.YELLOW)
    }

    @Test fun badVideoSkipsToPlayableItemAndAllBadShowsMessage() {
        File(context.filesDir, "bad.mp4").writeText("not a video")
        manifest(item("bad.mp4"), item("still.png"))
        launch()
        solid("11-bad-video-fallback", Color.WHITE)
        manifest(item("bad.mp4"))
        awaitPixels("12-all-bad-visible-error") { b ->
            var bright = 0
            for (y in b.height / 3 until b.height * 2 / 3 step 3)
                for (x in 0 until b.width step 3)
                    if (Color.red(b.getPixel(x,y)) > 160) bright++
            matches(b.getPixel(0,0), Color.rgb(28,28,32)) && bright > 20
        }.recycle()
        manifest(item("still.png"))
        solid("17-reapply-recovers-from-error", Color.WHITE)
    }

    @Test fun failedApplyPreservesPreviouslyAppliedPlaylist() {
        val valid = mapOf<String, Any?>("srcPath" to File(context.filesDir, "quadrants.mp4").path,
            "id" to "movie", "ext" to "mp4", "type" to "video", "zoom" to 2.0,
            "focusX" to .25, "focusY" to .25)
        WallpaperStore.applyLive(context, listOf(valid), 1, 1, false)
        val file = File(context.filesDir, "wallpaper_live.json")
        val original = file.readText()
        try {
            WallpaperStore.applyLive(context,
                listOf(valid, valid + ("srcPath" to "/missing.mp4")), 1, 1, false)
            fail("Missing source must be reported")
        } catch (_: IllegalStateException) {}
        assertEquals(original, file.readText())
        launch()
        solid("13-preserved-after-failed-apply", Color.RED)
    }

    @Test fun closingSystemPreviewDoesNotKillInstalledWallpaper() {
        manifest(item("quadrants.mp4", 2.0, .25, .25))
        launch()
        solid("14-main-before-preview", Color.RED)
        main { activity.addPreview() }
        val deadline = System.currentTimeMillis() + 15000
        var frames = 0
        while (frames < 5 && System.currentTimeMillis() < deadline) {
            main { frames = activity.preview?.renderedFrames ?: 0 }
            Thread.sleep(100)
        }
        assertTrue("Second engine must present frames", frames >= 5)
        main { activity.closePreview() }
        var before = 0
        main { before = activity.playback.renderedFrames }
        Thread.sleep(700)
        main { assertTrue(activity.playback.renderedFrames > before + 2) }
        solid("15-main-after-preview-closed", Color.RED)
    }

    @Test fun rotatedVideoUsesDisplayOrientation() {
        manifest(item("rotated.mp4"), seconds = 30)
        launch()
        awaitPixels("16-rotated-video") { b ->
            val scale = minOf(b.width / 240f, b.height / 320f)
            val dx = (60 * scale).toInt()
            val dy = (80 * scale).toInt()
            val x = b.width / 2
            val y = b.height / 2
            matches(b.getPixel(x-dx,y-dy), Color.GREEN) &&
                matches(b.getPixel(x+dx,y-dy), Color.YELLOW) &&
                matches(b.getPixel(x-dx,y+dy), Color.RED) &&
                matches(b.getPixel(x+dx,y+dy), Color.BLUE)
        }.recycle()
    }
}
