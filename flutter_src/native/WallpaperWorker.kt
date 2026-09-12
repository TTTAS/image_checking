package __PACKAGE__

import android.app.WallpaperManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.os.Build
import android.util.DisplayMetrics
import android.view.WindowManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

object WallpaperStore {
    private const val ROOT = "wallpaper_playlist"
    private const val MANIFEST = "wallpaper_rotation.json"
    const val WORK_NAME = "wallpaper_rotate"

    fun liveManifest(context: Context, side: String): File {
        require(side == "home" || side == "lock") { "Unknown wallpaper destination" }
        // Preserve the original home manifest for existing installations.
        return File(context.filesDir, if (side == "home") "wallpaper_live.json" else "wallpaper_live_lock.json")
    }

    private fun modes(context: Context) =
        context.getSharedPreferences("wallpaper_modes", Context.MODE_PRIVATE)

    private fun manifestFile(context: Context): File =
        File(context.filesDir, MANIFEST)

    private fun cropDir(context: Context, side: String): File =
        File(context.filesDir, "$ROOT/$side").apply { if (!exists()) mkdirs() }

    private fun sanitize(s: String): String = s.replace(Regex("[^A-Za-z0-9_-]"), "_")

    fun saveCropBytes(context: Context, bytes: ByteArray, side: String, id: String): String {
        val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw IllegalStateException("無法解碼圖片")
        return saveJpeg(context, bmp, side, id)
    }

    /// Fits the entire original inside the screen, centered, with black bars.
    /// Used at apply time for entries the user never cropped.
    fun centerCropSave(context: Context, srcPath: String, side: String, id: String): String {
        val (w, h) = screenSize(context)
        val src = decodeScaled(srcPath, w, h) ?: throw IllegalStateException("無法解碼圖片")
        val out = fitCenter(src, w, h)
        return saveJpeg(context, out, side, id)
    }

    private fun saveJpeg(context: Context, bmp: Bitmap, side: String, id: String): String {
        val f = File(cropDir(context, side), "${sanitize(id)}.jpg")
        f.outputStream().use { bmp.compress(Bitmap.CompressFormat.JPEG, 90, it) }
        return f.absolutePath
    }

    @Synchronized
    fun applyLive(
        context: Context,
        items: List<Map<String, Any?>>,
        seconds: Int,
        loops: Int,
        shuffle: Boolean,
        side: String = "home",
    ): Int {
        val manifest = liveManifest(context, side)
        val base = File(context.filesDir, "wallpaper_live").apply {
            if (!exists() && !mkdirs()) throw IllegalStateException("無法建立桌布資料夾")
        }
        val active = File(base, side)
        val staging = File(base, "staging_$side")
        val previous = File(base, "previous_$side")
        staging.deleteRecursively()
        if (!staging.mkdirs()) throw IllegalStateException("無法建立桌布暫存資料夾")

        val arr = JSONArray()
        for ((index, it) in items.withIndex()) {
            val src = it["srcPath"] as? String ?: continue
            val id = it["id"] as? String ?: continue
            val ext = ((it["ext"] as? String).let { e ->
                if (e.isNullOrEmpty()) "img" else e
            }).lowercase().replace(Regex("[^a-z0-9]"), "").ifEmpty { "img" }
            val from = File(src)
            if (!from.isFile || from.length() == 0L) {
                staging.deleteRecursively()
                throw IllegalStateException("桌布素材遺失或為空，已保留原桌布")
            }
            val name = "${index}_${sanitize(id)}.$ext"
            val stagedFile = File(staging, name)
            try {
                from.inputStream().use { input ->
                    stagedFile.outputStream().use { output -> input.copyTo(output) }
                }
                if (stagedFile.length() != from.length()) {
                    throw IllegalStateException("桌布素材複製不完整")
                }
            } catch (e: Exception) {
                staging.deleteRecursively()
                throw IllegalStateException("複製桌布素材失敗，已保留原桌布", e)
            }
            arr.put(JSONObject().apply {
                put("path", File(active, name).absolutePath)
                put("type", (it["type"] as? String) ?: "still")
                put("mime", (it["mime"] as? String) ?: "")
                put("width", (it["width"] as? Number)?.toInt() ?: 0)
                put("height", (it["height"] as? Number)?.toInt() ?: 0)
                put("zoom", (it["zoom"] as? Number)?.toDouble() ?: 0.0)
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
        if (arr.length() == 0) {
            staging.deleteRecursively()
            return 0
        }

        val oldManifest = try {
            if (manifest.exists()) manifest.readText() else null
        } catch (_: Exception) {
            null
        }
        previous.deleteRecursively()
        if (active.exists() && !active.renameTo(previous)) {
            staging.deleteRecursively()
            throw IllegalStateException("無法備份目前桌布")
        }
        if (!staging.renameTo(active)) {
            previous.renameTo(active)
            throw IllegalStateException("無法啟用新的桌布素材")
        }
        try {
            manifest.writeText(root.toString())
        } catch (e: Exception) {
            active.deleteRecursively()
            previous.renameTo(active)
            if (oldManifest != null) manifest.writeText(oldManifest) else manifest.delete()
            throw e
        }
        previous.deleteRecursively()
        modes(context).edit().putBoolean("live_$side", true).apply()
        return arr.length()
    }

    @Synchronized
    fun applyRotation(
        context: Context,
        homePaths: List<String>,
        lockPaths: List<String>,
        shuffle: Boolean,
    ) {
        modes(context).edit().apply {
            if (homePaths.isNotEmpty()) putBoolean("live_home", false)
            if (lockPaths.isNotEmpty()) putBoolean("live_lock", false)
        }.apply()
        val root = JSONObject().apply {
            put("home", JSONArray(homePaths))
            put("lock", JSONArray(lockPaths))
            put("homeOrder", JSONArray(order(homePaths.size, shuffle)))
            put("lockOrder", JSONArray(order(lockPaths.size, shuffle)))
            put("homePos", 0)
            put("lockPos", 0)
        }
        manifestFile(context).writeText(root.toString())
        applyAt(context, root, "home", "homeOrder", 0, 1)
        applyAt(context, root, "lock", "lockOrder", 0, 2)
    }

    private fun order(n: Int, shuffle: Boolean): List<Int> {
        val l = (0 until n).toMutableList()
        if (shuffle) l.shuffle()
        return l
    }

    @Synchronized
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

    private fun applyFile(context: Context, path: String, flags: Int) {
        val side = if (flags == 2) "lock" else "home"
        if (modes(context).getBoolean("live_$side", false)) return
        try {
            val (w, h) = screenSize(context)
            val bmp = decodeScaled(path, w, h) ?: return
            val out = fitCenter(bmp, w, h)
            applyBitmap(context, out, flags)
        } catch (_: Exception) {
        }
    }

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

    /// Scale the whole image to fit inside [w]x[h], centered on black.
    private fun fitCenter(src: Bitmap, w: Int, h: Int): Bitmap {
        val scale = minOf(w.toFloat() / src.width, h.toFloat() / src.height)
        val sw = (src.width * scale).toInt().coerceAtLeast(1)
        val sh = (src.height * scale).toInt().coerceAtLeast(1)
        val scaled = Bitmap.createScaledBitmap(src, sw, sh, true)
        if (sw == w && sh == h) return scaled
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        canvas.drawColor(Color.BLACK)
        canvas.drawBitmap(scaled, (w - sw) / 2f, (h - sh) / 2f, null)
        return out
    }
}

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
