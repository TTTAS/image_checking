package com.tttas.wallpapertest

import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import android.test.ActivityInstrumentationTestCase2
import android.view.PixelCopy
import android.view.SurfaceView
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Pixel-level regression for the former Canvas/video Surface producer conflict. */
@Suppress("DEPRECATION")
class RendererTest : ActivityInstrumentationTestCase2<RenderActivity>(RenderActivity::class.java) {
    private val main = Handler(Looper.getMainLooper())
    private fun ui(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun snapshot(view: SurfaceView): Bitmap {
        val result = Bitmap.createBitmap(320, 480, Bitmap.Config.ARGB_8888)
        val ready = CountDownLatch(1)
        val status = AtomicInteger(-1)
        ui { PixelCopy.request(view, result, { status.set(it); ready.countDown() }, main) }
        assertTrue("PixelCopy timed out", ready.await(5, TimeUnit.SECONDS))
        assertEquals("PixelCopy failed", PixelCopy.SUCCESS, status.get())
        return result
    }
    private fun checksum(bitmap: Bitmap): Long {
        var value = 0L
        for (y in 155 until 325 step 8) for (x in 10 until 310 step 8) {
            value = value * 31 + bitmap.getPixel(x, y)
        }
        return value
    }

    fun testImageVideoImageAndRecreatedEngine() {
        val screen = activity
        assertTrue("Surfaces not created", screen.ready.await(10, TimeUnit.SECONDS))
        val clip = File(screen.filesDir, "test.mp4")
        instrumentation.context.assets.open("test.mp4").use { input ->
            clip.outputStream().use { input.copyTo(it) }
        }
        var output: WallpaperRenderer? = null
        var other: WallpaperRenderer? = null
        var player: MediaPlayer? = null
        val frames = AtomicInteger(0)
        val error = AtomicReference<String?>(null)
        var fill = false
        val static = Bitmap.createBitmap(320, 480, Bitmap.Config.ARGB_8888)
        try {
            ui {
                output = WallpaperRenderer(screen.primary.holder.surface)
                other = WallpaperRenderer(screen.secondary.holder.surface)
            }
            // Recreate EGL on the same Surface to exercise Engine teardown/rebind.
            repeat(2) { round ->
                ui {
                    static.eraseColor(Color.MAGENTA)
                    output!!.drawBitmap(static, 320, 480)
                    other!!.drawBitmap(static, 320, 480)
                }
                snapshot(screen.primary).also {
                    assertEquals("Static image before video", Color.MAGENTA, it.getPixel(160, 240))
                    it.recycle()
                }
                frames.set(0)
                ui {
                    val renderer = output!!
                    val surface = renderer.createVideoSurface(main) {
                        try {
                            if (fill) {
                                renderer.drawVideo(320, 480, -266.6667f, 0f, 853.3333f, 480f)
                            } else {
                                renderer.drawVideo(320, 480, 0f, 150f, 320f, 180f)
                            }
                            frames.incrementAndGet()
                            // Another Engine makes its own EGL context current.
                            other!!.drawBitmap(static, 320, 480)
                        } catch (e: Exception) { error.set(e.stackTraceToString()) }
                    }
                    player = MediaPlayer().apply {
                        setDataSource(clip.absolutePath)
                        setSurface(surface)
                        setVolume(0f, 0f)
                        isLooping = true
                        setOnErrorListener { _, what, extra -> error.set("MediaPlayer $what/$extra"); true }
                        setOnPreparedListener { it.start() }
                        prepareAsync()
                    }
                }
                val deadline = System.currentTimeMillis() + 15000
                while (frames.get() < 5 && error.get() == null && System.currentTimeMillis() < deadline) {
                    Thread.sleep(50)
                }
                assertNull("Rendering error", error.get())
                assertTrue("No decoded video frames, round $round", frames.get() >= 5)
                val first = snapshot(screen.primary)
                assertEquals("Contain top letterbox", Color.BLACK, first.getPixel(160, 30))
                assertEquals("Contain bottom letterbox", Color.BLACK, first.getPixel(160, 450))
                assertTrue("Video content is still black", (160..310 step 8).any { y ->
                    (10..300 step 8).any { x -> first.getPixel(x, y) != Color.BLACK }
                })
                val before = checksum(first)
                first.recycle()
                Thread.sleep(850)
                snapshot(screen.primary).also {
                    assertTrue("Video is frozen on its fallback image", before != checksum(it))
                    it.recycle()
                }
                val previous = frames.get()
                ui { fill = true }
                val fillDeadline = System.currentTimeMillis() + 5000
                while (frames.get() < previous + 3 && System.currentTimeMillis() < fillDeadline) Thread.sleep(30)
                snapshot(screen.primary).also {
                    assertTrue("Fill mode left a top letterbox", (10..300 step 8).any { x -> it.getPixel(x, 30) != Color.BLACK })
                    it.recycle()
                }
                ui {
                    player!!.release()
                    player = null
                    output!!.releaseVideo()
                    static.eraseColor(Color.GREEN)
                    output!!.drawBitmap(static, 320, 480)
                }
                snapshot(screen.primary).also {
                    assertEquals("Image after video", Color.GREEN, it.getPixel(160, 240))
                    it.recycle()
                }
                ui {
                    fill = false
                    output!!.release()
                    output = WallpaperRenderer(screen.primary.holder.surface)
                }
            }
        } finally {
            ui {
                player?.release()
                output?.release()
                other?.release()
            }
            static.recycle()
        }
    }
}
