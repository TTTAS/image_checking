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
    private const val ROOT = "wallpaper_playlist"
    private const val MANIFEST = "wallpaper_rotation.json"
    const val WORK_NAME = "wallpaper_rotate"

    private fun manifestFile(context: Context): File =
        File(context.filesDir, MANIFEST)

    private fun cropDir(context: Context, side: String): File =
        File(context.filesDir, "$ROOT/$side").apply { if (!exists()) mkdirs() }

    private fun sanitize(s: String): String = s.replace(Regex("[^A-Za-z0-9_-]"), "_")

    /// Saves already-cropped PNG bytes (from the Dart crop page) as a JPEG at
    /// <side>/<id>.jpg. Returns the absolute path. ("儲存裁切" / "設為桌布")
    fun saveCropBytes(context: Context, bytes: ByteArray, side: String, id: String): String {
        val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw IllegalStateException("無法解碼圖片")
        return saveJpeg(context, bmp, side, id)
    }

    /// Center-crops an original file to the screen and saves it as <side>/<id>.jpg.
    /// Used at apply time for entries the user never cropped.
    fun centerCropSave(context: Context, srcPath: String, side: String, id: String): String {
        val (w, h) = screenSize(context)
        val src = decodeScaled(srcPath, w, h) ?: throw IllegalStateException("無法解碼圖片")
        val out = centerCrop(src, w, h)
        return saveJpeg(context, out, side, id)
    }

    private fun saveJpeg(context: Context, bmp: Bitmap, side: String, id: String): String {
        val f = File(cropDir(context, side), "${sanitize(id)}.jpg")
        f.outputStream().use { bmp.compress(Bitmap.CompressFormat.JPEG, 90, it) }
        return f.absolutePath
    }

    /// Live wallpaper (mode B): copies the ORIGINAL files (to keep animation)
    /// into the app's private dir and writes wallpaper_live.json for
    /// [PlaylistWallpaperService]. [items] entries carry srcPath / id / ext plus
    /// the normalized crop transform (zoom / focusX / focusY) and animated flag.
    /// Returns how many were copied.
    fun applyLive(
        context: Context,
        items: List<Map<String, Any?>>,
        seconds: Int,
        loops: Int,
        shuffle: Boolean,
    ): Int {
        val dir = File(context.filesDir, "wallpaper_live/home")
            .apply { if (!exists()) mkdirs() }
        dir.listFiles()?.forEach { it.delete() }

        val arr = JSONArray()
        for (it in items) {
            val src = it["srcPath"] as? String ?: continue
            val id = it["id"] as? String ?: continue
            val ext = (it["ext"] as? String).let { e -> if (e.isNullOrEmpty()) "img" else e }
            val from = File(src)
            if (!from.exists()) continue
            val dst = File(dir, "${sanitize(id)}.$ext")
            try {
                from.inputStream().use { input ->
                    dst.outputStream().use { output -> input.copyTo(output) }
                }
            } catch (_: Exception) {
                continue
            }
            arr.put(JSONObject().apply {
                put("path", dst.absolutePath)
                put("zoom", (it["zoom"] as? Number)?.toDouble() ?: 1.0)
                put("focusX", (it["focusX"] as? Number)?.toDouble() ?: 0.5)
                put("focusY", (it["focusY"] as? Number)?.toDouble() ?: 0.5)
                put("animated", (it["animated"] as? Boolean) ?: false)
            })
        }
        val root = JSONObject().apply {
            put("items", arr)
            put("seconds", seconds)
            put("loops", loops)
            put("shuffle", shuffle)
        }
        File(context.filesDir, "wallpaper_live.json").writeText(root.toString())
        return arr.length()
    }

    /// Schedules rotation for both lists. [homePaths]/[lockPaths] are ordered
    /// cropped-file paths; either may be empty (that side simply won't rotate).
    /// Sets the first image of each side immediately.
    fun applyRotation(
        context: Context,
        homePaths: List<String>,
        lockPaths: List<String>,
        shuffle: Boolean,
    ) {
        val root = JSONObject().apply {
            put("home", JSONArray(homePaths))
            put("lock", JSONArray(lockPaths))
            put("homeOrder", JSONArray(order(homePaths.size, shuffle)))
            put("lockOrder", JSONArray(order(lockPaths.size, shuffle)))
            put("homePos", 0)
            put("lockPos", 0)
        }
        manifestFile(context).writeText(root.toString())
        applyAt(context, root, "home", "homeOrder", 0, 1) // FLAG_SYSTEM
        applyAt(context, root, "lock", "lockOrder", 0, 2) // FLAG_LOCK
    }

    private fun order(n: Int, shuffle: Boolean): List<Int> {
        val l = (0 until n).toMutableList()
        if (shuffle) l.shuffle()
        return l
    }

    /// Advances both sides to their next image. Called by the periodic worker.
    fun advance(context: Context) {
        val root = readManifest(context) ?: return
        advanceSide(context, root, "home", "homeOrder", "homePos", 1)
        advanceSide(context, root, "lock", "lockOrder", "lockPos", 2)
        manifestFile(context).writeText(root.toString())
    }

    private fun advanceSide(
        context: Context,
        root: JSONObject,
        pathsKey: String,
        orderKey: String,
        posKey: String,
        flag: Int,
    ) {
        val order = root.optJSONArray(orderKey) ?: return
        if (order.length() == 0) return
        val next = (root.optInt(posKey, 0) + 1) % order.length()
        root.put(posKey, next)
        applyAt(context, root, pathsKey, orderKey, next, flag)
    }

    private fun applyAt(
        context: Context,
        root: JSONObject,
        pathsKey: String,
        orderKey: String,
        pos: Int,
        flag: Int,
    ) {
        val paths = root.optJSONArray(pathsKey) ?: return
        val order = root.optJSONArray(orderKey) ?: return
        if (order.length() == 0) return
        val p = pos.coerceIn(0, order.length() - 1)
        val idx = order.optInt(p, 0)
        val path = paths.optString(idx, "")
        if (path.isNotEmpty()) applyFile(context, path, flag)
    }

    private fun readManifest(context: Context): JSONObject? {
        return try {
            val f = manifestFile(context)
            if (!f.exists()) null else JSONObject(f.readText())
        } catch (_: Exception) {
            null
        }
    }

    /// Decodes a cropped file and sets it for [flags]. Cropped files are already
    /// screen-ratio, so the center-crop here is a safe no-op.
    private fun applyFile(context: Context, path: String, flags: Int) {
        try {
            val (w, h) = screenSize(context)
            val bmp = decodeScaled(path, w, h) ?: return
            val out = centerCrop(bmp, w, h)
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
