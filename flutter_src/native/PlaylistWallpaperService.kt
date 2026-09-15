package __PACKAGE__

import android.app.WallpaperManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Movie
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.drawable.Drawable
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.wallpaper.WallpaperService
import android.util.Log
import android.view.SurfaceHolder
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/// Live wallpaper playlist for still images, animated images, and videos.
///
/// Android 14+ exposes which screen owns each Engine, so HOME and LOCK can use
/// separate lists. Earlier Android versions do not expose that distinction to a
/// wallpaper service; they use HOME (or LOCK when HOME is empty).
class PlaylistWallpaperService : WallpaperService() {
    private data class Item(
        val path: String,
        val zoom: Float,
        val fx: Float,
        val fy: Float,
        val animated: Boolean,
        val video: Boolean,
    )

    override fun onCreateEngine(): Engine = PlaylistEngine()

    inner class PlaylistEngine : WallpaperService.Engine() {
        private val handler = Handler(Looper.getMainLooper())
        private val tag = "PlaylistWP"

        private val homeItems = mutableListOf<Item>()
        private val lockItems = mutableListOf<Item>()
        private var items: List<Item> = emptyList()
        private var order = mutableListOf<Int>()
        private var seconds = 30
        private var loops = 1
        private var shuffle = false
        private var pos = 0

        private var visible = false
        private var surfaceW = 0
        private var surfaceH = 0

        private var drawable: Drawable? = null
        private var movie: Movie? = null
        private var still: Bitmap? = null
        private var player: MediaPlayer? = null
        private var movieStart = 0L

        private var drawScale = 1f
        private var drawLeft = 0f
        private var drawTop = 0f
        private var imgW = 0
        private var imgH = 0

        private val tick = object : Runnable {
            override fun run() {
                if (!visible || player != null) return
                drawFrame()
                handler.postDelayed(this, 16L)
            }
        }

        override fun onCreate(surfaceHolder: SurfaceHolder) {
            super.onCreate(surfaceHolder)
            loadManifest()
        }

        override fun onSurfaceChanged(
            holder: SurfaceHolder,
            format: Int,
            width: Int,
            height: Int,
        ) {
            surfaceW = width
            surfaceH = height
            selectTargetList()
            if (visible) playCurrent(0)
        }

        override fun onVisibilityChanged(v: Boolean) {
            visible = v
            if (v) {
                selectTargetList()
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

        private fun parseItems(arr: JSONArray?, out: MutableList<Item>) {
            out.clear()
            if (arr == null) return
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val path = o.optString("path", "")
                if (path.isEmpty()) continue
                out.add(
                    Item(
                        path = path,
                        zoom = o.optDouble("zoom", 0.0).toFloat(),
                        fx = o.optDouble("focusX", 0.5).toFloat(),
                        fy = o.optDouble("focusY", 0.5).toFloat(),
                        animated = o.optBoolean("animated", false),
                        video = o.optBoolean("video", false),
                    )
                )
            }
        }

        private fun loadManifest() {
            try {
                val file = File(filesDir, "wallpaper_live.json")
                if (!file.exists()) {
                    Log.w(tag, "no wallpaper_live.json")
                    return
                }
                val root = JSONObject(file.readText())
                seconds = root.optInt("seconds", 30).coerceAtLeast(1)
                loops = root.optInt("loops", 1).coerceAtLeast(1)
                shuffle = root.optBoolean("shuffle", false)
                // Backward compatibility with manifests written by older builds.
                parseItems(
                    root.optJSONArray("homeItems") ?: root.optJSONArray("items"),
                    homeItems,
                )
                parseItems(root.optJSONArray("lockItems"), lockItems)
                selectTargetList()
                Log.i(
                    tag,
                    "loaded home=${homeItems.size} lock=${lockItems.size} seconds=$seconds",
                )
            } catch (e: Exception) {
                Log.e(tag, "loadManifest", e)
                homeItems.clear()
                lockItems.clear()
                items = emptyList()
            }
        }

        private fun wallpaperFlagsCompat(): Int {
            if (Build.VERSION.SDK_INT < 34) return WallpaperManager.FLAG_SYSTEM
            return try {
                val method = WallpaperService.Engine::class.java
                    .getMethod("getWallpaperFlags")
                (method.invoke(this) as? Int) ?: WallpaperManager.FLAG_SYSTEM
            } catch (_: Exception) {
                WallpaperManager.FLAG_SYSTEM
            }
        }

        private fun selectTargetList() {
            val flags = wallpaperFlagsCompat()
            val lockOnly = flags and WallpaperManager.FLAG_LOCK != 0 &&
                flags and WallpaperManager.FLAG_SYSTEM == 0
            items = when {
                lockOnly && lockItems.isNotEmpty() -> lockItems
                homeItems.isNotEmpty() -> homeItems
                else -> lockItems
            }
            order = (items.indices).toMutableList()
            if (shuffle) order.shuffle()
            if (pos !in order.indices) pos = 0
        }

        private fun stopAll() {
            handler.removeCallbacksAndMessages(null)
            try {
                player?.stop()
            } catch (_: Exception) {
            }
            try {
                player?.release()
            } catch (_: Exception) {
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
            try {
                when {
                    item.video || looksVideo(file) -> playVideo(file)
                    (item.animated || looksAnimated(file)) &&
                        tryPlayGifMovie(file, item) -> Unit
                    (item.animated || looksAnimated(file)) &&
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                        tryPlayAnimatedDrawable(file, item) -> Unit
                    else -> playStatic(file, item)
                }
            } catch (e: Exception) {
                Log.e(tag, "playCurrent", e)
                pos = (pos + 1) % order.size
                playCurrent(attempt + 1)
                return
            }

            val delayMs = seconds * 1000L
            handler.postDelayed({ advance() }, delayMs)
            if (player == null) handler.post(tick)
        }

        private fun looksVideo(file: File): Boolean {
            val n = file.name.lowercase()
            return n.endsWith(".mp4") || n.endsWith(".m4v") ||
                n.endsWith(".mov") || n.endsWith(".webm") ||
                n.endsWith(".3gp") || n.endsWith(".mkv")
        }

        private fun looksAnimated(file: File): Boolean {
            val n = file.name.lowercase()
            return n.endsWith(".gif") || n.endsWith(".webp")
        }

        private fun playVideo(file: File) {
            clearBlack()
            val mediaPlayer = MediaPlayer()
            player = mediaPlayer
            mediaPlayer.setDataSource(file.absolutePath)
            mediaPlayer.setSurface(surfaceHolder.surface)
            mediaPlayer.setVolume(0f, 0f)
            mediaPlayer.isLooping = true
            mediaPlayer.setVideoScalingMode(MediaPlayer.VIDEO_SCALING_MODE_SCALE_TO_FIT)
            mediaPlayer.setOnPreparedListener {
                if (visible && player === it) it.start()
            }
            mediaPlayer.setOnErrorListener { _, what, extra ->
                Log.w(tag, "video error what=$what extra=$extra file=${file.name}")
                handler.post { advance() }
                true
            }
            mediaPlayer.prepareAsync()
            Log.i(tag, "video ${file.name}")
        }

        @Suppress("DEPRECATION")
        private fun tryPlayGifMovie(file: File, item: Item): Boolean {
            if (!file.name.lowercase().endsWith(".gif")) return false
            val bytes = file.readBytes()
            val decoded = Movie.decodeByteArray(bytes, 0, bytes.size) ?: return false
            if (decoded.duration() <= 0 || decoded.width() <= 0) return false
            movie = decoded
            movieStart = SystemClock.uptimeMillis()
            computeTransform(item, decoded.width(), decoded.height())
            return true
        }

        private fun tryPlayAnimatedDrawable(file: File, item: Item): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
            val source = ImageDecoder.createSource(file)
            val decoded = ImageDecoder.decodeDrawable(source) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val longest = maxOf(info.size.width, info.size.height)
                val target = maxOf(surfaceW, surfaceH).coerceAtLeast(1)
                if (longest > target * 2) {
                    val scale = longest.toFloat() / (target * 2)
                    decoder.setTargetSize(
                        (info.size.width / scale).toInt().coerceAtLeast(1),
                        (info.size.height / scale).toInt().coerceAtLeast(1),
                    )
                }
            }
            if (decoded !is AnimatedImageDrawable) return false
            drawable = decoded
            computeTransform(
                item,
                decoded.intrinsicWidth.coerceAtLeast(1),
                decoded.intrinsicHeight.coerceAtLeast(1),
            )
            decoded.repeatCount = AnimatedImageDrawable.REPEAT_INFINITE
            decoded.start()
            return true
        }

        private fun playStatic(file: File, item: Item) {
            val bitmap = decodeScaled(file, maxOf(surfaceW, surfaceH))
                ?: throw IllegalStateException("decode failed")
            still = bitmap
            computeTransform(item, bitmap.width, bitmap.height)
        }

        private fun computeTransform(item: Item, width: Int, height: Int) {
            imgW = width
            imgH = height
            val contain = minOf(
                surfaceW.toFloat() / width,
                surfaceH.toFloat() / height,
            )
            val cover = maxOf(
                surfaceW.toFloat() / width,
                surfaceH.toFloat() / height,
            )
            // Default is contain/center: the whole item remains visible.
            drawScale = if (item.zoom <= 0f) {
                contain
            } else {
                cover * item.zoom.coerceAtLeast(0.1f)
            }
            drawLeft = surfaceW / 2f - drawScale * item.fx * width
            drawTop = surfaceH / 2f - drawScale * item.fy * height
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
                val currentMovie = movie
                val currentDrawable = drawable
                val bitmap = still
                when {
                    currentMovie != null -> {
                        val duration = currentMovie.duration().coerceAtLeast(1)
                        val time = (
                            (SystemClock.uptimeMillis() - movieStart) % duration
                            ).toInt()
                        currentMovie.setTime(time)
                        currentMovie.draw(canvas, 0f, 0f)
                    }
                    currentDrawable != null -> {
                        currentDrawable.setBounds(0, 0, imgW, imgH)
                        currentDrawable.draw(canvas)
                    }
                    bitmap != null -> canvas.drawBitmap(bitmap, 0f, 0f, null)
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
            val longest = maxOf(bounds.outWidth, bounds.outHeight)
            while (target > 0 && longest / (sample * 2) >= target) sample *= 2
            val options = BitmapFactory.Options().apply { inSampleSize = sample }
            return BitmapFactory.decodeFile(file.absolutePath, options)
        }
    }
}
