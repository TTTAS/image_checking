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
        val fallbackPath: String,
        // Index of the source playlist entry this window belongs to. Windows of
        // the same source item share a group so shuffle keeps them together and
        // in order.
        val group: Int,
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
        // Last home-screen page index seen from onOffsetsChanged; -1 = unsynced.
        private var lastPage = -1

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
        private val nextItem = Runnable { advance() }
        private val videoTimeout = Runnable {
            if (!firstVideoFrame && player != null) {
                reportError("影片未能在 15 秒內輸出畫面")
                releasePlayer()
                drawFrame()
                handler.postDelayed(nextItem, seconds * 1000L)
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

        /// Home-screen horizontal swipe. Each time the launcher moves to a
        /// different home page we step the window by one (wrapping), rather than
        /// mapping the raw scroll fraction onto the window index. That keeps the
        /// window count independent of the number of home pages — e.g. 3 windows
        /// on a 2-page launcher still cycle one-per-swipe — and avoids flashing
        /// intermediate windows mid-swipe.
        ///
        /// Launchers that lock wallpaper scrolling never call this (the page
        /// never changes), so the picture simply stays put until swiped.
        override fun onOffsetsChanged(
            xOffset: Float,
            yOffset: Float,
            xOffsetStep: Float,
            yOffsetStep: Float,
            xPixelOffset: Int,
            yPixelOffset: Int,
        ) {
            val n = order.size
            if (!visible || n <= 1) return
            // Discrete home page = scroll fraction / per-page step, rounded.
            val step = if (xOffsetStep.isNaN() || xOffsetStep <= 0f) 1f else xOffsetStep
            val x = if (xOffset.isNaN()) 0f else xOffset.coerceIn(0f, 1f)
            val page = Math.round(x / step)
            if (lastPage < 0) {
                lastPage = page
                return
            }
            if (page == lastPage) return
            val delta = page - lastPage
            lastPage = page
            var next = (pos + delta) % n
            if (next < 0) next += n
            pos = next
            handler.removeCallbacks(nextItem)
            playCurrent(0)
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
                // Expand the item's ordered crop windows into one Item each,
                // sharing the same media file but framed differently. All belong
                // to group [i] so they stay contiguous and in order after a
                // shuffle. Fall back to the top-level transform (single window)
                // for manifests written by older builds.
                val windows = o.optJSONArray("windows")
                if (windows != null && windows.length() > 0) {
                    for (w in 0 until windows.length()) {
                        val win = windows.optJSONObject(w) ?: continue
                        out.add(
                            Item(
                                path = path,
                                zoom = win.optDouble("zoom", 0.0).toFloat(),
                                fx = win.optDouble("focusX", 0.5).toFloat(),
                                fy = win.optDouble("focusY", 0.5).toFloat(),
                                animated = animated,
                                video = video,
                                fallbackPath = fallbackPath,
                                group = i,
                            )
                        )
                    }
                } else {
                    out.add(
                        Item(
                            path = path,
                            zoom = o.optDouble("zoom", 0.0).toFloat(),
                            fx = o.optDouble("focusX", 0.5).toFloat(),
                            fy = o.optDouble("focusY", 0.5).toFloat(),
                            animated = animated,
                            video = video,
                            fallbackPath = fallbackPath,
                            group = i,
                        )
                    )
                }
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
            order = buildOrder(items, shuffle)
            if (pos !in order.indices) pos = 0
            // Re-sync page tracking; the next offset event just records the page.
            lastPage = -1
        }

        /// Builds the playback order. Windows are grouped by their source item;
        /// shuffle only reorders the groups, never the windows inside a group,
        /// so a wide photo's left→right sequence always plays in order.
        private fun buildOrder(source: List<Item>, shuffleGroups: Boolean):
            MutableList<Int> {
            val groups = LinkedHashMap<Int, MutableList<Int>>()
            for (i in source.indices) {
                groups.getOrPut(source[i].group) { mutableListOf() }.add(i)
            }
            val groupKeys = groups.keys.toMutableList()
            if (shuffleGroups) groupKeys.shuffle()
            val result = mutableListOf<Int>()
            for (key in groupKeys) {
                groups[key]?.let { result.addAll(it) }
            }
            return result
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

        private fun advance() {
            if (order.isEmpty()) return
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

            // A window sequence is navigated by horizontal swipe only, so we do
            // NOT auto-advance on a timer. [tick] just keeps animated frames
            // (GIF/WebP) redrawing; still images stay put until the user swipes.
            if (player == null) {
                handler.post(tick)
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
                        handler.removeCallbacks(nextItem)
                        handler.postDelayed(nextItem, seconds * 1000L)
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
                        handler.postDelayed(nextItem, seconds * 1000L)
                    }
                }
            }
            mediaPlayer.setOnErrorListener { failed, what, extra ->
                if (player === failed) {
                    reportError("影片播放失敗：${file.name}（播放器錯誤 $what/$extra）")
                    handler.removeCallbacks(videoTimeout)
                    releasePlayer()
                    drawFrame()
                    handler.removeCallbacks(nextItem)
                    handler.postDelayed(nextItem, seconds * 1000L)
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

