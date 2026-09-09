package __PACKAGE__

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.drawable.Animatable2
import android.graphics.drawable.Drawable
import android.graphics.ImageDecoder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.wallpaper.WallpaperService
import android.view.SurfaceHolder
import org.json.JSONObject
import java.io.File

/// Dynamic (Live) wallpaper for mode B: plays the HOME playlist's animated
/// images (GIF / animated WebP) using API 28+ ImageDecoder / AnimatedImageDrawable.
///
/// Reads filesDir/wallpaper_live.json (written by WallpaperStore.applyLive), which
/// lists copied ORIGINAL files plus each item's normalized crop transform
/// (zoom / focusX / focusY). Frames are drawn to the wallpaper canvas with that
/// transform (clip), so animation is preserved (we never use the flattened crop
/// jpg here). Only animates while visible; advances to the next item after
/// liveSeconds (precedence) or loopsBeforeNext loops. Bad / missing files are
/// skipped without crashing.
class PlaylistWallpaperService : WallpaperService() {
    // Nested (not inner) so it can live alongside the inner Engine class.
    private data class Item(
        val path: String,
        val zoom: Float,
        val fx: Float,
        val fy: Float,
        val animated: Boolean,
    )

    override fun onCreateEngine(): Engine = PlaylistEngine()

    inner class PlaylistEngine : WallpaperService.Engine() {
        private val handler = Handler(Looper.getMainLooper())

        private val items = mutableListOf<Item>()
        private var order = mutableListOf<Int>()
        private var seconds = 30
        private var loops = 1
        private var pos = 0

        private var visible = false
        private var surfaceW = 0
        private var surfaceH = 0

        private var drawable: Drawable? = null
        // Precomputed draw transform for the current item.
        private var drawScale = 1f
        private var drawLeft = 0f
        private var drawTop = 0f
        private var imgW = 0
        private var imgH = 0

        private val invalidateCb = object : Drawable.Callback {
            override fun invalidateDrawable(who: Drawable) = drawOnce()
            override fun scheduleDrawable(who: Drawable, what: Runnable, at: Long) {
                handler.postAtTime(what, at)
            }
            override fun unscheduleDrawable(who: Drawable, what: Runnable) {
                handler.removeCallbacks(what)
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
            items.clear()
            try {
                val f = File(filesDir, "wallpaper_live.json")
                if (!f.exists()) return
                val root = JSONObject(f.readText())
                seconds = root.optInt("seconds", 30)
                loops = root.optInt("loops", 1).coerceAtLeast(1)
                val arr = root.optJSONArray("items") ?: return
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    items.add(
                        Item(
                            path = o.optString("path", ""),
                            zoom = o.optDouble("zoom", 1.0).toFloat(),
                            fx = o.optDouble("focusX", 0.5).toFloat(),
                            fy = o.optDouble("focusY", 0.5).toFloat(),
                            animated = o.optBoolean("animated", false),
                        )
                    )
                }
                order = (0 until items.size).toMutableList()
                if (root.optBoolean("shuffle", false)) order.shuffle()
                pos = 0
            } catch (_: Exception) {
                items.clear()
            }
        }

        private fun stopAll() {
            handler.removeCallbacksAndMessages(null)
            (drawable as? AnimatedImageDrawable)?.let {
                try {
                    it.stop()
                } catch (_: Exception) {
                }
            }
            drawable?.callback = null
            drawable = null
        }

        private fun advance() {
            if (order.isEmpty()) return
            pos = (pos + 1) % order.size
            playCurrent(0)
        }

        /// Plays the item at the current position. [attempt] guards against an all-
        /// bad list (skip broken files, but don't loop forever).
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
                pos = (pos + 1) % order.size
                playCurrent(attempt + 1)
                return
            }
            try {
                if (item.animated && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    playAnimated(file, item)
                } else {
                    playStatic(file, item)
                }
            } catch (_: Exception) {
                pos = (pos + 1) % order.size
                playCurrent(attempt + 1)
            }
        }

        private fun computeTransform(item: Item, w: Int, h: Int) {
            imgW = w
            imgH = h
            val cover = maxOf(surfaceW.toFloat() / w, surfaceH.toFloat() / h)
            drawScale = cover * item.zoom
            drawLeft = surfaceW / 2f - drawScale * item.fx * w
            drawTop = surfaceH / 2f - drawScale * item.fy * h
        }

        private fun playAnimated(file: File, item: Item) {
            val src = ImageDecoder.createSource(file)
            val d = ImageDecoder.decodeDrawable(src) { decoder, info, _ ->
                // Downscale to roughly the surface to bound memory.
                val long = maxOf(info.size.width, info.size.height)
                val target = maxOf(surfaceW, surfaceH)
                if (long > target && target > 0) {
                    decoder.setTargetSampleSize(
                        (long / target).coerceAtLeast(1)
                    )
                }
            }
            drawable = d
            computeTransform(item, d.intrinsicWidth, d.intrinsicHeight)
            if (d is AnimatedImageDrawable) {
                d.callback = invalidateCb
                if (seconds > 0) {
                    d.repeatCount = AnimatedImageDrawable.REPEAT_INFINITE
                } else {
                    d.repeatCount = (loops - 1).coerceAtLeast(0)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        d.registerAnimationCallback(object : Animatable2.AnimationCallback() {
                            override fun onAnimationEnd(who: Drawable) = advance()
                        })
                    }
                }
                d.start()
            }
            drawOnce()
            if (seconds > 0) {
                handler.postDelayed({ advance() }, seconds * 1000L)
            }
        }

        private fun playStatic(file: File, item: Item) {
            val bmp = decodeScaled(file, maxOf(surfaceW, surfaceH))
                ?: throw IllegalStateException("decode failed")
            drawable = null
            computeTransform(item, bmp.width, bmp.height)
            drawBitmapOnce(bmp)
            val delay = (if (seconds > 0) seconds else 5) * 1000L
            handler.postDelayed({ advance() }, delay)
        }

        private fun drawOnce() {
            val d = drawable ?: return
            val holder = surfaceHolder
            var canvas: Canvas? = null
            try {
                canvas = holder.lockCanvas() ?: return
                canvas.drawColor(Color.BLACK)
                canvas.save()
                canvas.translate(drawLeft, drawTop)
                canvas.scale(drawScale, drawScale)
                d.setBounds(0, 0, imgW, imgH)
                d.draw(canvas)
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

        private fun drawBitmapOnce(bmp: Bitmap) {
            val holder = surfaceHolder
            var canvas: Canvas? = null
            try {
                canvas = holder.lockCanvas() ?: return
                canvas.drawColor(Color.BLACK)
                canvas.save()
                canvas.translate(drawLeft, drawTop)
                canvas.scale(drawScale, drawScale)
                canvas.drawBitmap(bmp, 0f, 0f, null)
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
