package __PACKAGE__

import android.content.Context
import android.graphics.*
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.drawable.Drawable
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import org.json.JSONObject
import java.io.File

/** Also exercised by instrumented tests on a real Android Surface. Calls use the main thread. */
class WallpaperPlayback(private val context: Context) {
    private data class Item(
        val path: String, val zoom: Float, val fx: Float, val fy: Float,
        val video: Boolean, val animated: Boolean, val width: Int, val height: Int
    )
    private val handler = Handler(Looper.getMainLooper())
    private var renderer: WallpaperRenderer? = null
    private var visible = false
    private var width = 0
    private var height = 0
    private var items = emptyList<Item>()
    private var order = emptyList<Int>()
    private var pos = 0
    private var seconds = 30
    private var manifestText = ""
    private var generation = 0
    private var player: MediaPlayer? = null
    private var bitmap: Bitmap? = null
    private var drawable: Drawable? = null
    private var movie: Movie? = null
    private var frame: Bitmap? = null
    private var start = 0L
    private val failures = mutableSetOf<Int>()
    var renderedFrames = 0
        private set
    val hasPlayer: Boolean get() = player != null

    fun attach(surface: Surface, w: Int, h: Int) {
        detach()
        width = w
        height = h
        if (!surface.isValid || w <= 0 || h <= 0) return
        try {
            renderer = WallpaperRenderer(surface, w, h)
            if (visible) { loadManifest(); playCurrent() }
        } catch (e: Exception) { Log.e("PlaylistWP", "Cannot create rendering surface", e) }
    }

    fun setVisible(value: Boolean) {
        visible = value
        stop()
        if (value && renderer != null) {
            loadManifest()
            failures.clear()
            playCurrent()
        }
    }

    fun detach() {
        stop()
        try { renderer?.release() } catch (e: Exception) { Log.w("PlaylistWP", "Release surface", e) }
        renderer = null
    }

    private fun loadManifest() {
        try {
            val text = File(context.filesDir, "wallpaper_live.json").readText()
            if (text == manifestText) return
            val root = JSONObject(text)
            val array = root.getJSONArray("items")
            items = (0 until array.length()).map { i ->
                val o = array.getJSONObject(i)
                val path = o.getString("path")
                val ext = File(path).extension.lowercase()
                Item(path, o.optDouble("zoom", 0.0).toFloat(),
                    o.optDouble("focusX", .5).toFloat(), o.optDouble("focusY", .5).toFloat(),
                    o.optString("type") == "video" || o.optString("mime").startsWith("video/") ||
                        ext in listOf("mp4", "m4v", "webm", "3gp", "mov"),
                    o.optBoolean("animated") || ext in listOf("gif", "webp"),
                    o.optInt("width"), o.optInt("height"))
            }
            order = items.indices.toList().let { if (root.optBoolean("shuffle")) it.shuffled() else it }
            seconds = root.optInt("seconds", 30).coerceAtLeast(1)
            pos = 0
            manifestText = text
            failures.clear()
        } catch (e: Exception) { Log.e("PlaylistWP", "Cannot load wallpaper playlist", e) }
    }

    private fun stop() {
        generation++
        handler.removeCallbacksAndMessages(null)
        val old = player
        player = null
        try { old?.release() } catch (e: Exception) { Log.w("PlaylistWP", "Release player", e) }
        try { renderer?.releaseVideo() } catch (e: Exception) { Log.w("PlaylistWP", "Release video surface", e) }
        if (Build.VERSION.SDK_INT >= 28) (drawable as? AnimatedImageDrawable)?.stop()
        drawable?.callback = null
        drawable = null
        movie = null
        bitmap?.recycle()
        bitmap = null
        frame?.recycle()
        frame = null
    }

    private fun playCurrent() {
        stop()
        if (!visible || renderer == null) return
        if (order.isEmpty() || failures.size >= order.size) { showError(); return }
        var searched = 0
        while (order[pos] in failures && searched++ < order.size) pos = (pos + 1) % order.size
        val item = items[order[pos]]
        val token = generation
        try {
            require(File(item.path).isFile) { "Missing wallpaper file" }
            if (item.video) playVideo(item, token) else {
                loadImage(item)
                drawImage(item)
                if (movie != null || drawable != null) animate(item, token)
                scheduleAdvance(token)
            }
        } catch (e: Exception) { fail(token, e) }
    }

    private fun scheduleAdvance(token: Int) {
        handler.postDelayed({
            if (token == generation && visible) {
                val before = manifestText
                loadManifest()
                if (before != manifestText) playCurrent()
                else if (order.size == 1 && player != null) scheduleAdvance(token)
                else {
                    if (order.isNotEmpty()) pos = (pos + 1) % order.size
                    playCurrent()
                }
            }
        }, seconds * 1000L)
    }

    private fun playVideo(item: Item, token: Int) {
        val p = MediaPlayer()
        player = p
        var firstFrame = false
        var videoWidth = item.width
        var videoHeight = item.height
        val timeout = Runnable { fail(token, IllegalStateException("影片未能在 10 秒內開始播放")) }
        val surface = renderer!!.createVideoSurface(handler) {
            if (token == generation && visible && player === p) {
                try {
                    renderer!!.drawVideo(videoWidth, videoHeight, item.zoom, item.fx, item.fy)
                    renderedFrames++
                    if (!firstFrame) {
                        firstFrame = true
                        handler.removeCallbacks(timeout)
                        scheduleAdvance(token)
                        Log.i("PlaylistWP", "First video frame presented: ${File(item.path).name}")
                    }
                } catch (e: Exception) { fail(token, e) }
            }
        }
        p.setDataSource(item.path)
        p.setSurface(surface)
        p.setVolume(0f, 0f)
        p.isLooping = true
        p.setOnPreparedListener {
            if (token == generation && player === it && visible) {
                try {
                    if (videoWidth <= 0 || videoHeight <= 0) {
                        videoWidth = it.videoWidth
                        videoHeight = it.videoHeight
                    }
                    require(videoWidth > 0 && videoHeight > 0) { "No video track" }
                    it.start()
                } catch (e: Exception) { fail(token, e) }
            }
        }
        p.setOnErrorListener { _, what, extra ->
            fail(token, IllegalStateException("Video decoder error $what/$extra"))
            true
        }
        handler.postDelayed(timeout, 10000)
        p.prepareAsync()
    }

    private fun fail(token: Int, error: Exception) {
        if (token != generation) return
        Log.e("PlaylistWP", "Wallpaper item failed", error)
        if (order.isNotEmpty()) failures.add(order[pos])
        stop()
        // Never recurse through bad files, or a long broken playlist can overflow the stack.
        val nextToken = generation
        handler.post { if (visible && nextToken == generation) playCurrent() }
    }

    private fun showError() {
        val b = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(b)
        canvas.drawColor(Color.rgb(28, 28, 32))
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = width / 24f
            textAlign = Paint.Align.CENTER
        }
        canvas.drawText("桌布素材無法播放", width / 2f, height / 2f, paint)
        paint.textSize = width / 34f
        canvas.drawText("請返回相簿檢查素材後重新套用", width / 2f, height / 2f + width / 14f, paint)
        try { renderer?.drawBitmap(b) } finally { b.recycle() }
    }

    @Suppress("DEPRECATION")
    private fun loadImage(item: Item) {
        val file = File(item.path)
        if (item.animated && file.extension.equals("gif", true)) {
            movie = file.inputStream().use { Movie.decodeStream(it) }
            val m = movie
            if (m != null && m.duration() > 0) {
                frame = newFrame(m.width(), m.height())
                start = SystemClock.uptimeMillis()
                return
            }
            movie = null
        }
        if (item.animated && Build.VERSION.SDK_INT >= 28) {
            val d = ImageDecoder.decodeDrawable(ImageDecoder.createSource(file)) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val scale = minOf(1f, maxOf(width, height).toFloat() / maxOf(info.size.width, info.size.height))
                decoder.setTargetSize((info.size.width * scale).toInt().coerceAtLeast(1),
                    (info.size.height * scale).toInt().coerceAtLeast(1))
            }
            if (d is AnimatedImageDrawable) {
                drawable = d
                frame = newFrame(d.intrinsicWidth, d.intrinsicHeight)
                d.repeatCount = AnimatedImageDrawable.REPEAT_INFINITE
                d.start()
                return
            }
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(item.path, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) > maxOf(width, height)) sample *= 2
        bitmap = BitmapFactory.decodeFile(item.path, BitmapFactory.Options().apply { inSampleSize = sample })
        require(bitmap != null) { "Cannot decode image" }
    }

    private fun newFrame(w: Int, h: Int): Bitmap {
        val scale = minOf(1f, maxOf(width, height).toFloat() / maxOf(w, h).coerceAtLeast(1))
        return Bitmap.createBitmap((w * scale).toInt().coerceAtLeast(1),
            (h * scale).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
    }

    private fun drawImage(item: Item) {
        val b = bitmap ?: frame ?: return
        frame?.let {
            it.eraseColor(Color.TRANSPARENT)
            val canvas = Canvas(it) // Offscreen bitmap only. No lockCanvas on the output Surface.
            movie?.let { m ->
                canvas.scale(it.width.toFloat() / m.width(), it.height.toFloat() / m.height())
                m.setTime(((SystemClock.uptimeMillis() - start) % m.duration().coerceAtLeast(1)).toInt())
                m.draw(canvas, 0f, 0f)
            }
            drawable?.let { d -> d.setBounds(0, 0, it.width, it.height); d.draw(canvas) }
        }
        renderer!!.drawBitmap(b, item.zoom, item.fx, item.fy)
        renderedFrames++
    }

    private fun animate(item: Item, token: Int) {
        handler.postDelayed({
            if (token == generation && visible) {
                try { drawImage(item); animate(item, token) } catch (e: Exception) { fail(token, e) }
            }
        }, 32L)
    }
}
