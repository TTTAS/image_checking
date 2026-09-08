package __PACKAGE__

import android.app.WallpaperManager
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.TimeUnit

/// Adds a "photo_album/native" MethodChannel so Dart can:
///  - check / request the "All files access" (MANAGE_EXTERNAL_STORAGE) permission
///  - rename a real folder on disk and ask MediaStore to reindex it
///
/// This file is copied over the generated MainActivity by the CI workflow, with
/// __PACKAGE__ replaced by the app's real package name.
class MainActivity : FlutterActivity() {
    private val channelName = "photo_album/native"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
                    "requestAllFilesAccess" -> {
                        requestAllFilesAccess()
                        result.success(null)
                    }
                    "renameFolder" -> {
                        val oldPath = call.argument<String>("oldPath")
                        val newName = call.argument<String>("newName")
                        if (oldPath == null || newName == null) {
                            result.error("ARGS", "oldPath / newName required", null)
                        } else {
                            renameFolder(oldPath, newName, result)
                        }
                    }
                    "setWallpaper" -> {
                        val uri = call.argument<String>("uri")
                        if (uri == null) {
                            result.error("ARGS", "uri required", null)
                        } else {
                            setWallpaper(uri, result)
                        }
                    }
                    "applyStaticWallpaper" -> {
                        val items = call.argument<List<Map<String, Any?>>>("items")
                        val flags = call.argument<Int>("flags") ?: 1
                        val fit = call.argument<String>("fit") ?: "crop"
                        val shuffle = call.argument<Boolean>("shuffle") ?: false
                        val interval = call.argument<Int>("intervalMinutes") ?: 60
                        applyStaticWallpaper(items, flags, fit, shuffle, interval, result)
                    }
                    "cancelWallpaperWork" -> {
                        WorkManager.getInstance(applicationContext)
                            .cancelUniqueWork(WallpaperStore.WORK_NAME)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            true
        }
    }

    private fun requestAllFilesAccess() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
            intent.data = Uri.parse("package:$packageName")
            startActivity(intent)
        } catch (e: Exception) {
            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
    }

    /// Opens the system "crop & set wallpaper" screen for the image at [uriString]
    /// so the user can position/crop and pick which screen before applying.
    private fun setWallpaper(uriString: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(uriString)
            val wm = WallpaperManager.getInstance(applicationContext)
            val intent = wm.getCropAndSetWallpaperIntent(uri)
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            // Some devices lack a wallpaper cropper: fall back to the plain
            // "set as" chooser so the user can still apply it as wallpaper.
            try {
                val uri = Uri.parse(uriString)
                val fallback = Intent(Intent.ACTION_ATTACH_DATA).apply {
                    addCategory(Intent.CATEGORY_DEFAULT)
                    setDataAndType(uri, "image/*")
                    putExtra("mimeType", "image/*")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                startActivity(Intent.createChooser(fallback, "設為桌布"))
                result.success(true)
            } catch (e2: Exception) {
                result.error("EXCEPTION", e2.message ?: e.message, null)
            }
        }
    }

    /// Mode A (static rotation): copy the chosen files into the app's private
    /// dir, set the first one now, and schedule a periodic job to advance. Runs
    /// off the main thread because copying + decoding can take a moment.
    private fun applyStaticWallpaper(
        items: List<Map<String, Any?>>?,
        flags: Int,
        fit: String,
        shuffle: Boolean,
        intervalMinutes: Int,
        result: MethodChannel.Result,
    ) {
        val sources = items?.mapNotNull { it["path"] as? String } ?: emptyList()
        if (sources.isEmpty()) {
            result.error("EMPTY", "沒有可用的圖片檔", null)
            return
        }
        Thread {
            try {
                val count =
                    WallpaperStore.setup(applicationContext, sources, flags, fit, shuffle)
                if (count == 0) {
                    runOnUiThread { result.error("COPY_FAILED", "無法複製任何圖片", null) }
                    return@Thread
                }
                scheduleRotation(intervalMinutes)
                runOnUiThread { result.success(count) }
            } catch (e: Exception) {
                runOnUiThread { result.error("EXCEPTION", e.message, null) }
            }
        }.start()
    }

    /// Schedules (or replaces) the periodic rotation job. WorkManager's real
    /// floor is ~15 minutes, so anything shorter is clamped up.
    private fun scheduleRotation(intervalMinutes: Int) {
        val minutes = intervalMinutes.toLong().coerceAtLeast(15L)
        val request = PeriodicWorkRequest.Builder(
            WallpaperWorker::class.java,
            minutes,
            TimeUnit.MINUTES,
        ).build()
        WorkManager.getInstance(applicationContext).enqueueUniquePeriodicWork(
            WallpaperStore.WORK_NAME,
            ExistingPeriodicWorkPolicy.UPDATE,
            request,
        )
    }

    private fun renameFolder(oldPath: String, newName: String, result: MethodChannel.Result) {
        try {
            val dir = File(oldPath)
            if (!dir.exists() || !dir.isDirectory) {
                result.error("NOT_FOUND", "資料夾不存在: $oldPath", null)
                return
            }
            val safe = newName.trim()
            if (safe.isEmpty() || safe.contains('/') || safe == "." || safe == "..") {
                result.error("BAD_NAME", "名稱不合法", null)
                return
            }
            val target = File(dir.parentFile, safe)
            if (target.exists()) {
                result.error("EXISTS", "已存在同名資料夾", null)
                return
            }
            if (!dir.renameTo(target)) {
                result.error("RENAME_FAILED", "改名失敗（可能沒有權限或跨儲存區）", null)
                return
            }
            // Ask MediaStore to drop the old paths and pick up the new ones.
            val paths = mutableListOf(oldPath, target.absolutePath)
            target.walkTopDown().forEach { if (it.isFile) paths.add(it.absolutePath) }
            MediaScannerConnection.scanFile(applicationContext, paths.toTypedArray(), null, null)
            result.success(target.absolutePath)
        } catch (e: Exception) {
            result.error("EXCEPTION", e.message, null)
        }
    }
}
