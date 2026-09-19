package __PACKAGE__

import android.app.WallpaperManager
import android.content.ComponentName
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
///  - create a Pictures subfolder and move files into a folder
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
                    "picturesDir" -> result.success(picturesDir().absolutePath)
                    "createFolder" -> {
                        val name = call.argument<String>("name")
                        if (name == null) {
                            result.error("ARGS", "name required", null)
                        } else {
                            createFolder(name, result)
                        }
                    }
                    "moveFiles" -> {
                        val srcPaths = call.argument<List<String>>("srcPaths")
                        val destDir = call.argument<String>("destDir")
                        if (srcPaths == null || destDir == null) {
                            result.error("ARGS", "srcPaths / destDir required", null)
                        } else {
                            moveFiles(srcPaths, destDir, result)
                        }
                    }
                    "setWallpaperBytes" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val flags = call.argument<Int>("flags") ?: 1
                        if (bytes == null) {
                            result.error("ARGS", "bytes required", null)
                        } else {
                            setWallpaperBytes(bytes, flags, result)
                        }
                    }
                    "saveCrop" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val side = call.argument<String>("side") ?: "home"
                        val id = call.argument<String>("id")
                        if (bytes == null || id == null) {
                            result.error("ARGS", "bytes / id required", null)
                        } else {
                            runOffThread(result) {
                                WallpaperStore.saveCropBytes(applicationContext, bytes, side, id)
                            }
                        }
                    }
                    "centerCropSave" -> {
                        val src = call.argument<String>("srcPath")
                        val side = call.argument<String>("side") ?: "home"
                        val id = call.argument<String>("id")
                        if (src == null || id == null) {
                            result.error("ARGS", "srcPath / id required", null)
                        } else {
                            runOffThread(result) {
                                WallpaperStore.centerCropSave(applicationContext, src, side, id)
                            }
                        }
                    }
                    "renderCropSave" -> {
                        val src = call.argument<String>("srcPath")
                        val side = call.argument<String>("side") ?: "home"
                        val id = call.argument<String>("id")
                        val zoom = (call.argument<Double>("zoom") ?: 0.0).toFloat()
                        val focusX = (call.argument<Double>("focusX") ?: 0.5).toFloat()
                        val focusY = (call.argument<Double>("focusY") ?: 0.5).toFloat()
                        if (src == null || id == null) {
                            result.error("ARGS", "srcPath / id required", null)
                        } else {
                            runOffThread(result) {
                                WallpaperStore.renderCropSave(
                                    applicationContext, src, side, id, zoom, focusX, focusY,
                                )
                            }
                        }
                    }
                    "applyRotation" -> {
                        val home = call.argument<List<String>>("home") ?: emptyList()
                        val lock = call.argument<List<String>>("lock") ?: emptyList()
                        val shuffle = call.argument<Boolean>("shuffle") ?: false
                        val interval = call.argument<Int>("intervalMinutes") ?: 60
                        applyRotation(home, lock, shuffle, interval, result)
                    }
                    "applyLive" -> {
                        val homeItems =
                            call.argument<List<Map<String, Any?>>>("homeItems") ?: emptyList()
                        val lockItems =
                            call.argument<List<Map<String, Any?>>>("lockItems") ?: emptyList()
                        val seconds = call.argument<Int>("seconds") ?: 30
                        val loops = call.argument<Int>("loops") ?: 1
                        val shuffle = call.argument<Boolean>("shuffle") ?: false
                        if (homeItems.isEmpty() && lockItems.isEmpty()) {
                            result.error("ARGS", "homeItems / lockItems required", null)
                        } else {
                            applyLive(homeItems, lockItems, seconds, loops, shuffle, result)
                        }
                    }
                    "openLiveWallpaperPreview" -> openLiveWallpaperPreview(result)
                    "liveWallpaperDiagnostics" -> {
                        val errorFile = File(filesDir, "wallpaper_live_error.txt")
                        val statusFile = File(filesDir, "wallpaper_live_status.txt")
                        val device = "${Build.MANUFACTURER} ${Build.MODEL} / Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})"
                        val error = if (errorFile.exists()) errorFile.readText() else "尚未記錄錯誤"
                        val status = if (statusFile.exists()) statusFile.readText() else "尚未記錄桌布引擎活動"
                        result.success("$device\n\n$error\n\n$status")
                    }
                    "liveWallpaperError" -> {
                        val errorFile = File(filesDir, "wallpaper_live_error.txt")
                        result.success(if (errorFile.exists()) errorFile.readText() else "")
                    }
                    "cancelWallpaperWork" -> {
                        try {
                            WorkManager.getInstance(applicationContext)
                                .cancelUniqueWork(WallpaperStore.WORK_NAME)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("EXCEPTION", e.message, null)
                        }
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

    private fun picturesDir(): File {
        return Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
    }

    private fun safeFolderName(name: String): String? {
        val safe = name.trim()
        if (safe.isEmpty() || safe.contains('/') || safe.contains('\\') ||
            safe == "." || safe == ".."
        ) {
            return null
        }
        return safe
    }

    private fun createFolder(name: String, result: MethodChannel.Result) {
        val safe = safeFolderName(name)
        if (safe == null) {
            result.error("BAD_NAME", "名稱不合法", null)
            return
        }
        try {
            val dir = File(picturesDir(), safe)
            if (!dir.exists() && !dir.mkdirs()) {
                result.error("CREATE_FAILED", "無法建立資料夾", null)
                return
            }
            MediaScannerConnection.scanFile(
                applicationContext,
                arrayOf(dir.absolutePath),
                null,
                null,
            )
            result.success(dir.absolutePath)
        } catch (e: Exception) {
            result.error("EXCEPTION", e.message, null)
        }
    }

    private fun uniqueTarget(dest: File, originalName: String): File {
        val candidate = File(dest, originalName)
        if (!candidate.exists()) return candidate
        val dot = originalName.lastIndexOf('.')
        val base = if (dot > 0) originalName.substring(0, dot) else originalName
        val ext = if (dot > 0) originalName.substring(dot) else ""
        var i = 1
        while (true) {
            val next = File(dest, "${base}_$i$ext")
            if (!next.exists()) return next
            i++
        }
    }

    /// Physically moves files into [destDir], then asks MediaStore to reindex
    /// both the old and new paths so the folder tab picks the change up.
    private fun moveFiles(srcPaths: List<String>, destDir: String, result: MethodChannel.Result) {
        Thread {
            try {
                val dest = File(destDir)
                if (!dest.exists() && !dest.mkdirs()) {
                    runOnUiThread { result.error("CREATE_FAILED", "無法建立目標資料夾", null) }
                    return@Thread
                }
                if (!dest.isDirectory) {
                    runOnUiThread { result.error("NOT_DIR", "目標不是資料夾", null) }
                    return@Thread
                }
                var moved = 0
                val scan = mutableListOf<String>()
                for (src in srcPaths) {
                    val file = File(src)
                    if (!file.exists() || !file.isFile) continue
                    if (file.parentFile?.absolutePath == dest.absolutePath) {
                        moved++
                        continue
                    }
                    val target = uniqueTarget(dest, file.name)
                    val ok = file.renameTo(target)
                    if (!ok) {
                        file.copyTo(target, overwrite = false)
                        file.delete()
                    }
                    scan.add(src)
                    scan.add(target.absolutePath)
                    moved++
                }
                if (scan.isNotEmpty()) {
                    MediaScannerConnection.scanFile(
                        applicationContext,
                        scan.toTypedArray(),
                        null,
                        null,
                    )
                }
                runOnUiThread { result.success(moved) }
            } catch (e: Exception) {
                runOnUiThread { result.error("EXCEPTION", e.message, null) }
            }
        }.start()
    }

    private fun setWallpaperBytes(bytes: ByteArray, flags: Int, result: MethodChannel.Result) {
        Thread {
            try {
                val honored = WallpaperStore.setWallpaperBytes(applicationContext, bytes, flags)
                runOnUiThread { result.success(honored) }
            } catch (e: Exception) {
                runOnUiThread { result.error("EXCEPTION", e.message, null) }
            }
        }.start()
    }

    private fun runOffThread(result: MethodChannel.Result, work: () -> String) {
        Thread {
            try {
                val out = work()
                runOnUiThread { result.success(out) }
            } catch (e: Exception) {
                runOnUiThread { result.error("EXCEPTION", e.message, null) }
            }
        }.start()
    }

    private fun applyRotation(
        home: List<String>,
        lock: List<String>,
        shuffle: Boolean,
        intervalMinutes: Int,
        result: MethodChannel.Result,
    ) {
        if (home.isEmpty() && lock.isEmpty()) {
            result.error("EMPTY", "沒有可輪播的圖片", null)
            return
        }
        Thread {
            try {
                WallpaperStore.applyRotation(applicationContext, home, lock, shuffle)
                scheduleRotation(intervalMinutes)
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                runOnUiThread { result.error("EXCEPTION", e.message, null) }
            }
        }.start()
    }

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

    private fun applyLive(
        homeItems: List<Map<String, Any?>>,
        lockItems: List<Map<String, Any?>>,
        seconds: Int,
        loops: Int,
        shuffle: Boolean,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val n = WallpaperStore.applyLive(
                    applicationContext,
                    homeItems,
                    lockItems,
                    seconds,
                    loops,
                    shuffle,
                )
                if (n == 0) {
                    runOnUiThread { result.error("EMPTY", "沒有可用的動態圖片", null) }
                } else {
                    runOnUiThread { result.success(n) }
                }
            } catch (e: Exception) {
                runOnUiThread { result.error("EXCEPTION", e.message, null) }
            }
        }.start()
    }

    private fun openLiveWallpaperPreview(result: MethodChannel.Result) {
        try {
            val intent = Intent(WallpaperManager.ACTION_CHANGE_LIVE_WALLPAPER).apply {
                putExtra(
                    WallpaperManager.EXTRA_LIVE_WALLPAPER_COMPONENT,
                    ComponentName(this@MainActivity, PlaylistWallpaperService::class.java),
                )
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("EXCEPTION", e.message, null)
        }
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
            val paths = mutableListOf(oldPath, target.absolutePath)
            target.walkTopDown().forEach { if (it.isFile) paths.add(it.absolutePath) }
            MediaScannerConnection.scanFile(applicationContext, paths.toTypedArray(), null, null)
            result.success(target.absolutePath)
        } catch (e: Exception) {
            result.error("EXCEPTION", e.message, null)
        }
    }
}

