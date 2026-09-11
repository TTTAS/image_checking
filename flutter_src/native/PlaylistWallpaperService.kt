package __PACKAGE__

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Movie
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.drawable.Drawable
import android.graphics.ImageDecoder
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.wallpaper.WallpaperService
import android.util.Log
import android.view.SurfaceHolder
import org.json.JSONObject
import java.io.File

/// Live wallpaper: plays the HOME playlist (video / GIF / animated WebP / stills).
/// Videos decode directly to the wallpaper Surface. Only animated images use
/// the 16ms Canvas loop; stills draw once. Returning home restarts the current
/// item from frame 0.
class PlaylistWallpaperService : WallpaperService() {
    private data class Item(
        val path: String,
        val zoom: Float,
        val fx: Float,
        val fy: Float,
        val animated: Boolean,
        val type: String,
        val mime: String,
    )

    override fun onCreateEngine(): Engine = PlaylistEngine()

    inner class PlaylistEngine : WallpaperService.Engine() {
        private val handler = Handler(Looper.getMainLooper())
        private val tag = "PlaylistWP"

        private val items = mutableListOf<Item>()
        private var order = mutableListOf<Int>()
        private var seconds = 30
        private var pos = 0
        private var manifestModified = -1L

        private var visible = false
        private var surfaceW = 0
        private var surfaceH = 0

        private var drawable: Drawable? = null
        private var movie: Movie? = null
        private var still: Bitmap? = null
        private var player: MediaPlayer? = null
        private var movieStart = 0L
        private var generation = 0

        private var drawScale = 1f
        private var drawLeft = 0f
        private var drawTop = 0f
        private var imgW = 0
        private var imgH = 0

        private val tick = object : Runnable {
            override fun run() {
                if (!visible) return
                drawFrame()
                handler.postDelayed(this, 16L)
            }
        }

        override fun onCreate(surfaceHolder: SurfaceHolder) {
            super.onCreate(surfaceHolder)
            loadManifest()
        }

        override fun onSurfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            surfaceW = width
            surfaceH = height
            if (visible) playCurrent(0)
        }

        override fun onVisibilityChanged(v: Boolean) {
            visible = v
            if (v) {
                reloadManifestIfChanged()
                playCurrent(0)
            } else {
                stopAll()
            }
        }

        override fun onSurfaceDestroyed(holder: SurfaceHolder) {
            stopAll()
            super.onSurfaceDestroyed(holder)
        }

        override fun onDestroy() {
            stopAll()
            super.onDestroy()
        }

        private fun loadManifest() {
            try {
                val f = File(filesDir, "wallpaper_live.json")
                if (!f.exists()) {
                    Log.w(tag, "no wallpaper_live.json")
                    items.clear()
                    manifestModified = -1L
                    return
                }
                val root = JSONObject(f.readText())
                val loaded = mutableListOf<Item>()
                val arr = root.optJSONArray("items") ?: return
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    loaded.add(
                        Item(
                            path = o.optString("path", ""),
                            zoom = o.optDouble("zoom", 0.0).toFloat(),
                            fx = o.optDouble("focusX", 0.5).toFloat(),
                            fy = o.optDouble("focusY", 0.5).toFloat(),
                            animated = o.optBoolean("animated", false),
                            type = o.optString("type", ""),
                            mime = o.optString("mime", ""),
                        )
                    )
                }
                items.clear()
                items.addAll(loaded)
                seconds = root.optInt("seconds", 30)
                order = (0 until items.size).toMutableList()
                if (root.optBoolean("shuffle", false)) order.shuffle()
                pos = 0
                manifestModified = f.lastModified()
                Log.i(tag, "loaded ${items.size} items seconds=$seconds")
            } catch (e: Exception) {
                Log.e(tag, "loadManifest", e)
                items.clear()
            }
        }

        private fun reloadManifestIfChanged() {
            val f = File(filesDir, "wallpaper_live.json")
            if (!f.exists() || f.lastModified() != manifestModified) loadManifest()
        }

        private fun stopAll() {
            generation++
            handler.removeCallbacksAndMessages(null)
            player?.let {
                try {
                    it.setSurface(null)
                    it.release()
                } catch (_: Exception) {
                }
            }
            player = null
            (drawable as? AnimatedImageDrawable)?.let {
                try {
                    it.stop()
                } catch (_: Exception) {
                }
            }
            drawable?.callback = null
            drawable = null
            movie = null
            still?.recycle()
            still = null
        }

        private fun advance() {
            if (order.isEmpty()) return
            pos = (pos + 1) % order.size
            playCurrent(0)
        }

        private fun playCurrent(attempt: Int) {
            stopAll()
            if (!visible || surfaceW <= 0 || surfaceH <= 0) return
            if (order.isEmpty() || attempt > order.size) {
                clearBlack()
                return
            }
            val item = items.getOrNull(order[pos]) ?: return
            val file = File(item.path)
            if (!file.exists()) {
                Log.w(tag, "missing ${item.path}")
                pos = (pos + 1) % order.size
                playCurrent(attempt + 1)
                return
            }
            val token = generation
            if (looksVideo(item, file)) {
                playVideo(file, token, attempt)
                return
            }
            try {
                val wantAnim = item.animated || looksAnimated(file)
                if (wantAnim && tryPlayGifMovie(file, item)) {
                    // ok
                } else if (wantAnim && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                    tryPlayAnimatedDrawable(file, item)
                ) {
                    // ok
                } else {
                    playStatic(file, item)
                }
            } catch (e: Exception) {
                Log.e(tag, "playCurrent", e)
                pos = (pos + 1) % order.size
                playCurrent(attempt + 1)
                return
            }
            scheduleAdvance()
            if (movie != null || drawable != null) {
                handler.post(tick)
            } else {
                drawFrame()
            }
        }

        private fun scheduleAdvance() {
            val delayMs = (if (seconds > 0) seconds else 8) * 1000L
            handler.postDelayed({ advance() }, delayMs)
        }

        private fun looksVideo(item: Item, file: File): Boolean {
            if (item.type.equals("video", ignoreCase = true)) return true
            if (item.mime.startsWith("video/", ignoreCase = true)) return true
            return when (file.extension.lowercase()) {
                "mp4", "m4v", "webm", "3gp", "mov" -> true
                else -> false
            }
        }

        private fun playVideo(file: File, token: Int, attempt: Int) {
            clearBlack()
            try {
                val p = MediaPlayer()
                player = p
                p.setDataSource(file.absolutePath)
                p.setSurface(surfaceHolder.surface)
                p.setVolume(0f, 0f)
                p.isLooping = true
                p.setScreenOnWhilePlaying(false)
                p.setOnPreparedListener { ready ->
                    if (token != generation || !visible || player !== ready) {
                        try {
                            ready.release()
                        } catch (_: Exception) {
                        }
                        return@setOnPreparedListener
                    }
                    try {
                        ready.setVideoScalingMode(
                            MediaPlayer.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING
                        )
                        ready.start()
                        scheduleAdvance()
                        Log.i(tag, "video ${file.name} ${ready.videoWidth}x${ready.videoHeight}")
                    } catch (e: Exception) {
                        Log.e(tag, "start video ${file.name}", e)
                        skipFailedVideo(ready, token, attempt)
                    }
                }
                p.setOnErrorListener { failed, what, extra ->
                    Log.e(tag, "video error ${file.name} what=$what extra=$extra")
                    skipFailedVideo(failed, token, attempt)
                    true
                }
                p.prepareAsync()
            } catch (e: Exception) {
                Log.e(tag, "prepare video ${file.name}", e)
                skipFailedVideo(player, token, attempt)
            }
        }

        private fun skipFailedVideo(failed: MediaPlayer?, token: Int, attempt: Int) {
            if (token != generation) return
            if (player === failed) player = null
            try {
                failed?.release()
            } catch (_: Exception) {
            }
            pos = (pos + 1) % order.size.coerceAtLeast(1)
            playCurrent(attempt + 1)
        }

        private fun looksAnimated(file: File): Boolean {
            val n = file.name.lowercase()
            return n.endsWith(".gif") || n.endsWith(".webp")
        }

        @Suppress("DEPRECATION")
        private fun tryPlayGifMovie(file: File, item: Item): Boolean {
            if (!file.name.lowercase().endsWith(".gif")) return false
            val bytes = file.readBytes()
            val m = Movie.decodeByteArray(bytes, 0, bytes.size) ?: return false
            if (m.duration() <= 0 || m.width() <= 0) return false
            movie = m
            movieStart = SystemClock.uptimeMillis()
            computeTransform(item, m.width(), m.height())
            Log.i(tag, "Movie gif ${file.name} ${m.width()}x${m.height()} dur=${m.duration()}")
            return true
        }

        private fun tryPlayAnimatedDrawable(file: File, item: Item): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
            val src = ImageDecoder.createSource(file)
            val d = ImageDecoder.decodeDrawable(src) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val long = maxOf(info.size.width, info.size.height)
                val target = maxOf(surfaceW, surfaceH).coerceAtLeast(1)
                if (long > target * 2) {
                    val scale = long.toFloat() / (target * 2)
                    decoder.setTargetSize(
                        (info.size.width / scale).toInt().coerceAtLeast(1),
                        (info.size.height / scale).toInt().coerceAtLeast(1),
                    )
                }
            }
            if (d !is AnimatedImageDrawable) {
                Log.i(tag, "decode not animated: ${d.javaClass.simpleName}")
                return false
            }
            drawable = d
            computeTransform(item, d.intrinsicWidth.coerceAtLeast(1), d.intrinsicHeight.coerceAtLeast(1))
            d.repeatCount = AnimatedImageDrawable.REPEAT_INFINITE
            d.start()
            Log.i(tag, "AnimatedImageDrawable ${file.name} ${d.intrinsicWidth}x${d.intrinsicHeight}")
            return true
        }

        private fun playStatic(file: File, item: Item) {
            val bmp = decodeScaled(file, maxOf(surfaceW, surfaceH))
                ?: throw IllegalStateException("decode failed")
            still = bmp
            computeTransform(item, bmp.width, bmp.height)
            Log.i(tag, "static ${file.name} ${bmp.width}x${bmp.height}")
        }

        private fun computeTransform(item: Item, w: Int, h: Int) {
            imgW = w
            imgH = h
            val contain = minOf(surfaceW.toFloat() / w, surfaceH.toFloat() / h)
            val cover = maxOf(surfaceW.toFloat() / w, surfaceH.toFloat() / h)
            // zoom <= 0: fit entire image centered (letterbox).
            // zoom == 1: classic cover-center crop. >1 further zoom.
            drawScale = if (item.zoom <= 0f) contain else cover * item.zoom.coerceAtLeast(0.1f)
            drawLeft = surfaceW / 2f - drawScale * item.fx * w
            drawTop = surfaceH / 2f - drawScale * item.fy * h
        }

        private fun drawFrame() {
            val holder = surfaceHolder
            var canvas: Canvas? = null
            try {
                canvas = holder.lockCanvas() ?: return
                canvas.drawColor(Color.BLACK)
                canvas.save()
                canvas.translate(drawLeft, drawTop)
                canvas.scale(drawScale, drawScale)
                val m = movie
                val d = drawable
                val b = still
                when {
                    m != null -> {
                        val dur = m.duration().coerceAtLeast(1)
                        val t = ((SystemClock.uptimeMillis() - movieStart) % dur).toInt()
                        m.setTime(t)
                        m.draw(canvas, 0f, 0f)
                    }
                    d != null -> {
                        d.setBounds(0, 0, imgW, imgH)
                        d.draw(canvas)
                    }
                    b != null -> canvas.drawBitmap(b, 0f, 0f, null)
                }
                canvas.restore()
            } catch (_: Exception) {
            } finally {
                if (canvas != null) {
                    try {
                        holder.unlockCanvasAndPost(canvas)
                    } catch (_: Exception) {
                    }
                }
            }
        }

        private fun clearBlack() {
            val holder = surfaceHolder
            var canvas: Canvas? = null
            try {
                canvas = holder.lockCanvas() ?: return
                canvas.drawColor(Color.BLACK)
            } catch (_: Exception) {
            } finally {
                if (canvas != null) {
                    try {
                        holder.unlockCanvasAndPost(canvas)
                    } catch (_: Exception) {
                    }
                }
            }
        }

        private fun decodeScaled(file: File, target: Int): Bitmap? {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, bounds)
            if (bounds.outWidth <= 0) return null
            var sample = 1
            val long = maxOf(bounds.outWidth, bounds.outHeight)
            while (target > 0 && long / (sample * 2) >= target) sample *= 2
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            return BitmapFactory.decodeFile(file.absolutePath, opts)
        }
    }
}
