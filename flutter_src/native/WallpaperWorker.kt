package __PACKAGE__

import android.app.WallpaperManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.util.DisplayMetrics
import android.view.WindowManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/// Static wallpaper rotation (mode A).
///
/// [WallpaperStore] owns the on-disk state: it copies the chosen files into the
/// app's private dir, writes a small JSON manifest, and knows how to set the
/// "current" image and advance to the next one. [WallpaperWorker] is the
/// WorkManager job that fires periodically (even when the app is dead) and just
/// asks the store to advance.
///
/// This is deliberately all-native: the actual work (decode + WallpaperManager)
/// is Android's, and keeping it here means the periodic job never needs to wake
/// Flutter. GIF / animated WebP only show their first frame in this mode — real
/// animation is the live wallpaper (mode B / M3).
object WallpaperStore {
    private const val DIR = "wallpaper_playlist"
    private const val MANIFEST = "wallpaper_playlist.json"
    const val WORK_NAME = "wallpaper_rotate"

    private fun dir(context: Context): File =
        File(context.filesDir, DIR).apply { if (!exists()) mkdirs() }

    private fun manifestFile(context: Context): File =
        File(context.filesDir, MANIFEST)

    /// Copies [sources] into the private dir, writes the manifest, and sets the
    /// first image immediately. Returns how many files were successfully copied.
    fun setup(
        context: Context,
        sources: List<String>,
        flags: Int,
        fit: String,
        shuffle: Boolean,
    ): Int {
        val dir = dir(context)
        // Fresh copy every time "apply" is pressed — no incremental sync.
        dir.listFiles()?.forEach { it.delete() }

        val copied = mutableListOf<String>()
        for ((i, src) in sources.withIndex()) {
            try {
                val from = File(src)
                if (!from.exists()) continue
                val ext = from.extension.ifEmpty { "img" }
                val dst = File(dir, "$i.$ext")
                from.inputStream().use { input ->
                    dst.outputStream().use { output -> input.copyTo(output) }
                }
                copied.add(dst.absolutePath)
            } catch (_: Exception) {
                // Skip a bad source instead of failing the whole apply.
            }
        }
        if (copied.isEmpty()) return 0

        val order = copied.indices.toMutableList()
        if (shuffle) order.shuffle()

        val json = JSONObject().apply {
            put("paths", JSONArray(copied))
            put("order", JSONArray(order))
            put("pos", 0)
            put("flags", flags)
            put("fit", fit)
        }
        manifestFile(context).writeText(json.toString())

        // Show the first one right away so "apply" has an instant effect.
        setCurrent(context)
        return copied.size
    }

    /// Sets the image at the current position.
    private fun setCurrent(context: Context) {
        val json = readManifest(context) ?: return
        val paths = json.optJSONArray("paths") ?: return
        val order = json.optJSONArray("order") ?: return
        if (order.length() == 0) return
        val pos = json.optInt("pos", 0).coerceIn(0, order.length() - 1)
        val idx = order.optInt(pos, 0)
        val path = paths.optString(idx, "")
        if (path.isEmpty()) return
        applyFile(context, path, json.optInt("flags", 1), json.optString("fit", "crop"))
    }

    /// Advances to the next image and sets it. Called by the periodic worker.
    fun advance(context: Context) {
        val json = readManifest(context) ?: return
        val order = json.optJSONArray("order") ?: return
        val paths = json.optJSONArray("paths") ?: return
        if (order.length() == 0) return
        val next = (json.optInt("pos", 0) + 1) % order.length()
        json.put("pos", next)
        manifestFile(context).writeText(json.toString())
        val idx = order.optInt(next, 0)
        val path = paths.optString(idx, "")
        if (path.isNotEmpty()) {
            applyFile(context, path, json.optInt("flags", 1), json.optString("fit", "crop"))
        }
    }

    private fun readManifest(context: Context): JSONObject? {
        return try {
            val f = manifestFile(context)
            if (!f.exists()) null else JSONObject(f.readText())
        } catch (_: Exception) {
            null
        }
    }

    /// Decodes [path] (down-sampled to the screen), center-crops it to fill, and
    /// sets it as the wallpaper for the requested screens ([flags]).
    private fun applyFile(context: Context, path: String, flags: Int, fit: String) {
        try {
            val (w, h) = screenSize(context)
            val bmp = decodeScaled(path, w, h) ?: return
            val out = if (fit == "contain") bmp else centerCrop(bmp, w, h)
            applyBitmap(context, out, flags)
        } catch (_: Exception) {
            // A bad frame must never crash the worker or the app.
        }
    }

    /// Sets [bmp] as the wallpaper for [flags] (1=home, 2=lock, 3=both).
    /// Returns true if the per-screen flags were honored (Android N+); false on
    /// older devices where only a single wallpaper can be set. Shared by the
    /// rotation worker and the in-app crop page.
    fun applyBitmap(context: Context, bmp: Bitmap, flags: Int): Boolean {
        val wm = WallpaperManager.getInstance(context)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            wm.setBitmap(bmp, null, true, if (flags == 0) 1 else flags)
            true
        } else {
            wm.setBitmap(bmp)
            false
        }
    }

    /// Sets an already-cropped PNG/JPEG (as bytes, sized by the caller to the
    /// screen) as the wallpaper. Pure decode + setBitmap — never opens any system
    /// UI. Returns whether per-screen [flags] were honored (Android N+).
    fun setWallpaperBytes(context: Context, bytes: ByteArray, flags: Int): Boolean {
        val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw IllegalStateException("無法解碼圖片")
        return applyBitmap(context, bmp, flags)
    }

    private fun screenSize(context: Context): Pair<Int, Int> {
        return try {
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val dm = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(dm)
            val w = if (dm.widthPixels > 0) dm.widthPixels else 1080
            val h = if (dm.heightPixels > 0) dm.heightPixels else 1920
            Pair(w, h)
        } catch (_: Exception) {
            Pair(1080, 1920)
        }
    }

    private fun decodeScaled(path: String, reqW: Int, reqH: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= reqW &&
            bounds.outHeight / (sample * 2) >= reqH
        ) {
            sample *= 2
        }
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        return BitmapFactory.decodeFile(path, opts)
    }

    private fun centerCrop(src: Bitmap, w: Int, h: Int): Bitmap {
        val scale = maxOf(w.toFloat() / src.width, h.toFloat() / src.height)
        val sw = (src.width * scale).toInt().coerceAtLeast(1)
        val sh = (src.height * scale).toInt().coerceAtLeast(1)
        val scaled = Bitmap.createScaledBitmap(src, sw, sh, true)
        val x = ((sw - w) / 2).coerceIn(0, maxOf(0, sw - 1))
        val y = ((sh - h) / 2).coerceIn(0, maxOf(0, sh - 1))
        val cw = minOf(w, sw - x)
        val ch = minOf(h, sh - y)
        return Bitmap.createBitmap(scaled, x, y, cw, ch)
    }
}

/// The periodic job WorkManager runs (~every 15+ minutes) to swap to the next
/// image. Failures are swallowed so a single bad file never crashes the job.
class WallpaperWorker(context: Context, params: WorkerParameters) :
    Worker(context, params) {
    override fun doWork(): Result {
        return try {
            WallpaperStore.advance(applicationContext)
            Result.success()
        } catch (_: Exception) {
            Result.success()
        }
    }
}
