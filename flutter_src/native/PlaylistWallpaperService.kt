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
    // One framing keyframe of an item's image.
    private data class Win(val zoom: Float, val fx: Float, val fy: Float)

    private data class Item(
        val path: String,
        val animated: Boolean,
        val video: Boolean,
        val fallbackPath: String,
        // Ordered framing keyframes. The horizontal scroll fraction is
        // interpolated across these so the picture pans smoothly (not a
        // slideshow). Always at least one.
        val windows: List<Win>,
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
        // Seconds between automatic rotations to the NEXT item (different image).
        // Windows within one item are navigated by swipe only, never on a timer.
        private var intervalSeconds = 300
        // Current item being shown, plus the continuous horizontal scroll
        // fraction (0..1) the launcher reports; used to pan the picture smoothly.
        private var current: Item? = null
        private var xFrac = 0f

        private var visible = false
        private var surfaceW = 0
        private var surfaceH = 0

        private var drawable: Drawable? = null
        private var movie: Movie? = null
        private var still: Bitmap? = null
        private var player: MediaPlayer? = null
        private var renderer: WallpaperRenderer? = null
        private var frameBitmap: Bitmap? = null
        private var playbackGeneration = 0
        private var firstVideoFrame = false
        // Timed rotation to the next item (different image).
        private val nextItem = Runnable { advance() }
        // Throttled skip past an item whose media failed to load.
        private val skipBroken = Runnable { advance() }
        private val videoTimeout = Runnable {
            if (!firstVideoFrame && player != null) {
                reportError("影片未能在 15 秒內輸出畫面")
                releasePlayer()
                drawFrame()
                handler.postDelayed(skipBroken, 3000L)
            }
        }
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
                if (movie != null || drawable != null) handler.postDelayed(this, 33L)
            }
        }

        override fun onCreate(surfaceHolder: SurfaceHolder) {
            super.onCreate(surfaceHolder)
            recordStatus("Engine 建立；系統預覽=$isPreview")
            loadManifest()
        }

        override fun onSurfaceCreated(holder: SurfaceHolder) {
            super.onSurfaceCreated(holder)
            recordStatus("Surface 建立；有效=${holder.surface.isValid}")
        }

        override fun onSurfaceChanged(
            holder: SurfaceHolder,
            format: Int,
            width: Int,
            height: Int,
        ) {
            stopAll()
            surfaceW = width
            surfaceH = height
            recordStatus("Surface 尺寸 ${width}x${height}；可見=$visible")
            if (renderer == null && holder.surface.isValid) {
                try {
                    renderer = WallpaperRenderer(holder.surface)
                } catch (e: Exception) {
                    reportError("桌布繪圖器初始化失敗", e)
                    return
                }
            }
            // The service can outlive the app. Always reload because applying a
            // new playlist replaces the private media files and manifest.
            loadManifest()
            if (visible) playCurrent(0)
        }

        override fun onVisibilityChanged(v: Boolean) {
            visible = v
            recordStatus("可見狀態=$v")
            if (v) {
                // A live wallpaper Engine is commonly reused across multiple
                // apply operations; its old file paths may no longer exist.
                loadManifest()
                playCurrent(0)
            } else {
                stopAll()
            }
        }

        /// Home-screen horizontal swipe. The launcher reports the scroll position
        /// as [xOffset] in 0..1; we track it continuously and pan the current
        /// picture across its framing keyframes so the image slides smoothly with
        /// the finger (not a slideshow). Switching to a different picture is the
        /// timer's job, not the swipe's.
        ///
        /// Launchers that lock wallpaper scrolling keep xOffset constant, so the
        /// picture simply stays put.
        override fun onOffsetsChanged(
            xOffset: Float,
            yOffset: Float,
            xOffsetStep: Float,
            yOffsetStep: Float,
            xPixelOffset: Int,
            yPixelOffset: Int,
        ) {
            if (!visible) return
            val nx = if (xOffset.isNaN()) 0f else xOffset.coerceIn(0f, 1f)
            if ((nx - xFrac).isNaN() || (nx - xFrac) == 0f) return
            xFrac = nx
            val item = current ?: return
            if (imgW > 0 && imgH > 0) {
                computeTransform(item, imgW, imgH)
                // Stills/GIF: redraw now. Video: the next decoded frame uses the
                // updated transform.
                if (player == null) drawFrame()
            }
            // Keep interacting from being cut off by the rotation timer.
            handler.removeCallbacks(nextItem)
            if (order.size > 1) {
                handler.postDelayed(nextItem, intervalSeconds * 1000L)
            }
        }

        override fun onSurfaceDestroyed(holder: SurfaceHolder) {
            stopAll()
            renderer?.release()
            renderer = null
            surfaceW = 0
            surfaceH = 0
            super.onSurfaceDestroyed(holder)
        }

        override fun onDestroy() {
            stopAll()
            renderer?.release()
            renderer = null
            super.onDestroy()
        }

        private fun parseItems(arr: JSONArray?, out: MutableList<Item>) {
            out.clear()
            if (arr == null) return
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val path = o.optString("path", "")
                if (path.isEmpty()) continue
                val animated = o.optBoolean("animated", false)
                val video = o.optBoolean("video", false)
                val fallbackPath = o.optString("fallbackPath", "")
                // Read the item's ordered framing keyframes; fall back to the
                // top-level transform (single window) for older manifests.
                val wins = mutableListOf<Win>()
                val windows = o.optJSONArray("windows")
                if (windows != null && windows.length() > 0) {
                    for (w in 0 until windows.length()) {
                        val win = windows.optJSONObject(w) ?: continue
                        wins.add(
                            Win(
                                zoom = win.optDouble("zoom", 0.0).toFloat(),
                                fx = win.optDouble("focusX", 0.5).toFloat(),
                                fy = win.optDouble("focusY", 0.5).toFloat(),
                            )
                        )
                    }
                }
                if (wins.isEmpty()) {
                    wins.add(
                        Win(
                            zoom = o.optDouble("zoom", 0.0).toFloat(),
                            fx = o.optDouble("focusX", 0.5).toFloat(),
                            fy = o.optDouble("focusY", 0.5).toFloat(),
                        )
                    )
                }
                out.add(
                    Item(
                        path = path,
                        animated = animated,
                        video = video,
                        fallbackPath = fallbackPath,
                        windows = wins,
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
                // New seconds key; fall back to the old minute key ×60.
                intervalSeconds = root.optInt(
                    "intervalSeconds",
                    root.optInt("intervalMinutes", 5) * 60,
                ).coerceAtLeast(1)
                // Backward compatibility with manifests written by older builds.
                parseItems(
                    root.optJSONArray("homeItems") ?: root.optJSONArray("items"),
                    homeItems,
                )
                parseItems(root.optJSONArray("lockItems"), lockItems)
                selectTargetList()
                recordStatus("載入清單：主畫面 ${homeItems.size}、鎖定 ${lockItems.size}、本引擎 ${items.size}")
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

        private fun recordStatus(message: String) {
            try {
                synchronized(PlaylistWallpaperService::class.java) {
                    val file = File(filesDir, "wallpaper_live_status.txt")
                    val previous = if (file.exists()) file.readLines().takeLast(39) else emptyList()
                    file.writeText((previous + "${java.util.Date()} [${hashCode()}] $message")
                        .joinToString("\n"))
                }
            } catch (_: Exception) { }
        }

        private fun reportError(message: String, error: Exception? = null) {
            val detail = if (error == null) message else "$message：${error.message}"
            Log.e(tag, detail, error)
            recordStatus(detail)
            try {
                File(filesDir, "wallpaper_live_error.txt").writeText(
                    "${java.util.Date()}\n$detail\n" + (error?.stackTraceToString() ?: ""))
            } catch (_: Exception) { }
        }

        private fun releasePlayer() {
            playbackGeneration++
            val old = player
            player = null
            old?.setOnPreparedListener(null)
            old?.setOnErrorListener(null)
            old?.setOnVideoSizeChangedListener(null)
            try { old?.release() } catch (_: Exception) { }
            try { renderer?.releaseVideo() } catch (e: Exception) {
                reportError("釋放影片輸出失敗", e)
            }
        }

        private fun stopAll() {
            handler.removeCallbacksAndMessages(null)
            releasePlayer()
            (drawable as? AnimatedImageDrawable)?.let {
                try { it.stop() } catch (_: Exception) { }
            }
            drawable?.callback = null
            drawable = null
            movie = null
            still?.recycle()
            still = null
            frameBitmap?.recycle()
            frameBitmap = null
        }

        /// Move to the next item (different picture). No-op with a single item.
        private fun advance() {
            if (order.size <= 1) return
            pos = (pos + 1) % order.size
            playCurrent(0)
        }

        private fun playCurrent(attempt: Int) {
            stopAll()
            if (!visible || surfaceW <= 0 || surfaceH <= 0 || renderer == null) return
            if (order.isEmpty() || attempt > order.size) {
                reportError("沒有可播放的桌布項目，或所有檔案均讀取失敗")
                clearBlack()
                return
            }
            val item = items.getOrNull(order[pos]) ?: return
            current = item
            val file = File(item.path)
            if (!file.exists()) {
                reportError("找不到桌布檔案：${item.path}")
                pos = (pos + 1) % order.size
                playCurrent(attempt + 1)
                return
            }
            try {
                when {
                    item.video || looksVideo(file) -> playVideo(file, item)
                    (item.animated || looksAnimated(file)) &&
                        tryPlayGifMovie(file, item) -> Unit
                    (item.animated || looksAnimated(file)) &&
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                        tryPlayAnimatedDrawable(file, item) -> Unit
                    else -> playStatic(file, item)
                }
            } catch (e: Exception) {
                reportError("載入桌布失敗：${file.name}", e)
                pos = (pos + 1) % order.size
                playCurrent(attempt + 1)
                return
            }

            // Swipe pans within the current picture; [tick] keeps animated
            // frames (GIF/WebP) redrawing. Different pictures rotate on a timer.
            if (player == null) {
                handler.post(tick)
            }
            handler.removeCallbacks(nextItem)
            if (order.size > 1) {
                handler.postDelayed(nextItem, intervalSeconds * 1000L)
            }
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

        private fun playVideo(file: File, item: Item) {
            val output = renderer ?: return
            clearBlack()
            val fallback = item.fallbackPath.takeIf { it.isNotEmpty() }?.let(::File)
            if (fallback?.exists() == true) {
                still = decodeScaled(fallback, maxOf(surfaceW, surfaceH))
                still?.let {
                    computeTransform(item, it.width, it.height)
                    drawFrame()
                }
            }
            firstVideoFrame = false
            recordStatus("開始準備影片：${file.name}，${file.length()} bytes")
            val generation = playbackGeneration
            val mediaPlayer = MediaPlayer()
            player = mediaPlayer
            val decoderSurface = output.createVideoSurface(handler) {
                if (visible && player === mediaPlayer && generation == playbackGeneration) {
                    try {
                        output.drawVideo(surfaceW, surfaceH, drawLeft, drawTop,
                            imgW * drawScale, imgH * drawScale)
                        if (!firstVideoFrame) {
                            firstVideoFrame = true
                            handler.removeCallbacks(videoTimeout)
                            // Swipe-only: the video loops in place; no auto-advance.
                            recordStatus("已繪出影片第一幀：${file.name}")
                        }
                    } catch (e: Exception) {
                        reportError("影片畫面輸出失敗：${file.name}", e)
                        handler.removeCallbacks(videoTimeout)
                        releasePlayer()
                        drawFrame()
                        handler.postDelayed(skipBroken, 3000L)
                    }
                }
            }
            mediaPlayer.setDataSource(file.absolutePath)
            // The decoder never receives the wallpaper Surface.
            mediaPlayer.setSurface(decoderSurface)
            mediaPlayer.setVolume(0f, 0f)
            mediaPlayer.isLooping = true
            mediaPlayer.setOnVideoSizeChangedListener { current, w, h ->
                if (player === current && w > 0 && h > 0) computeTransform(item, w, h)
            }
            mediaPlayer.setOnPreparedListener { current ->
                if (visible && player === current && generation == playbackGeneration) {
                    try {
                        computeTransform(item, current.videoWidth.coerceAtLeast(1),
                            current.videoHeight.coerceAtLeast(1))
                        recordStatus("影片已解碼：${current.videoWidth}x${current.videoHeight}，等待繪製")
                        current.start()
                    } catch (e: Exception) {
                        reportError("啟動影片失敗：${file.name}", e)
                        releasePlayer()
                        drawFrame()
                        handler.postDelayed(skipBroken, 3000L)
                    }
                }
            }
            mediaPlayer.setOnErrorListener { failed, what, extra ->
                if (player === failed) {
                    reportError("影片播放失敗：${file.name}（播放器錯誤 $what/$extra）")
                    handler.removeCallbacks(videoTimeout)
                    releasePlayer()
                    drawFrame()
                    handler.postDelayed(skipBroken, 3000L)
                }
                true
            }
            handler.postDelayed(videoTimeout, 15000L)
            mediaPlayer.prepareAsync()
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
            fun scaleOf(w: Win) =
                if (w.zoom <= 0f) contain else cover * w.zoom.coerceAtLeast(0.1f)

            val wins = item.windows
            val frac = xFrac.coerceIn(0f, 1f)
            var scale: Float
            var fx: Float
            var fy: Float
            if (wins.size >= 2) {
                // Treat windows as keyframes; the scroll fraction interpolates
                // continuously between them so the picture pans smoothly.
                val p = frac * (wins.size - 1)
                val i0 = p.toInt().coerceIn(0, wins.size - 1)
                val i1 = (i0 + 1).coerceAtMost(wins.size - 1)
                val f = p - i0
                val a = wins[i0]
                val b = wins[i1]
                scale = scaleOf(a) + (scaleOf(b) - scaleOf(a)) * f
                fx = a.fx + (b.fx - a.fx) * f
                fy = a.fy + (b.fy - a.fy) * f
            } else {
                val w0 = wins.firstOrNull() ?: Win(0f, 0.5f, 0.5f)
                scale = scaleOf(w0)
                if (w0.zoom <= 0f) {
                    // Whole image visible (letterboxed): nothing to pan.
                    fx = 0.5f
                    fy = 0.5f
                } else {
                    // Single window = show EXACTLY the framed crop (WYSIWYG):
                    // honor the saved focus so the wallpaper matches the crop
                    // preview and stays put. (To pan a wide picture across the
                    // home-screen scroll, add multiple windows — the >=2 branch
                    // above interpolates between them.)
                    fx = w0.fx
                    fy = w0.fy
                }
            }
            drawScale = scale
            drawLeft = surfaceW / 2f - drawScale * fx * width
            drawTop = surfaceH / 2f - drawScale * fy * height
        }

        private fun drawFrame() {
            val output = renderer ?: return
            if (surfaceW <= 0 || surfaceH <= 0) return
            try {
                // Software Canvas draws ONLY into a private Bitmap, never into
                // the system Surface. EGL uploads that bitmap for presentation.
                val ratio = minOf(1f, 1080f / maxOf(surfaceW, surfaceH))
                val width = (surfaceW * ratio).toInt().coerceAtLeast(1)
                val height = (surfaceH * ratio).toInt().coerceAtLeast(1)
                var buffer = frameBitmap
                if (buffer == null || buffer.width != width || buffer.height != height) {
                    buffer?.recycle()
                    buffer = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    frameBitmap = buffer
                }
                val canvas = Canvas(buffer)
                canvas.drawColor(Color.BLACK)
                canvas.scale(ratio, ratio)
                canvas.translate(drawLeft, drawTop)
                canvas.scale(drawScale, drawScale)
                val currentMovie = movie
                val currentDrawable = drawable
                val bitmap = still
                when {
                    currentMovie != null -> {
                        val duration = currentMovie.duration().coerceAtLeast(1)
                        val time = ((SystemClock.uptimeMillis() - movieStart) % duration).toInt()
                        currentMovie.setTime(time)
                        currentMovie.draw(canvas, 0f, 0f)
                    }
                    currentDrawable != null -> {
                        currentDrawable.setBounds(0, 0, imgW, imgH)
                        currentDrawable.draw(canvas)
                    }
                    bitmap != null -> canvas.drawBitmap(bitmap, 0f, 0f, null)
                }
                output.drawBitmap(buffer, surfaceW, surfaceH)
            } catch (e: Exception) {
                reportError("圖片畫面輸出失敗", e)
            }
        }

        private fun clearBlack() {
            try {
                renderer?.clear(surfaceW, surfaceH)
            } catch (e: Exception) {
                reportError("桌布清除畫面失敗", e)
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

