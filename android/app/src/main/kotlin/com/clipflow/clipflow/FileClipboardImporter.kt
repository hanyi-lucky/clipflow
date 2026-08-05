package com.clipflow.clipflow

import android.content.ClipData
import android.content.ClipDescription
import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * 文件剪贴板导入器（Android）。
 *
 * 在 URI 授权窗口内把 content:// 文件流式预拷贝到应用私有 cacheDir，只向
 * Dart 返回元数据（path/name/mimeType/size/lastModified/temp/errorCode），
 * 文件字节绝不整块走 MethodChannel。单线程 executor 串行处理，避免并发
 * 拷贝相互覆盖。
 */
class FileClipboardImporter(
    private val context: Context,
    private val channel: MethodChannel
) {
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 上一次已处理（或正在处理）的剪贴板签名，用于避免重复导入。 */
    @Volatile
    private var lastImportedClipSignature: String? = null

    @Volatile
    private var lastImportedFiles: List<Map<String, Any>> = emptyList()

    @Volatile
    private var shutDown = false

    /** 后台监听回调：拷贝当前剪贴板文件后通过 channel 通知 Dart。 */
    fun importClipboard(clip: ClipData?) {
        val signature = clipSignature(clip)
        if (signature == null || signature == lastImportedClipSignature) {
            return
        }
        lastImportedClipSignature = signature
        lastImportedFiles = emptyList()
        if (shutDown) {
            return
        }
        try {
            executor.execute {
                val result = processClipboard(clip)
                lastImportedFiles = result
                if (result.isNotEmpty()) {
                    // Flutter MethodChannel 的 invokeMethod 必须在主线程执行
                    mainHandler.post {
                        channel.invokeMethod("onClipboardFilesChanged", result)
                    }
                }
            }
        } catch (e: RejectedExecutionException) {
            lastImportedClipSignature = null
        }
    }

    /** 前台主动查询：同一剪贴板已导入则直接返回缓存，否则现场导入。 */
    fun getFilesAsync(clip: ClipData?, runOnResult: (List<Map<String, Any>>) -> Unit) {
        val signature = clipSignature(clip)
        if (signature != null && signature == lastImportedClipSignature) {
            runOnResult(lastImportedFiles)
            return
        }
        if (shutDown) {
            runOnResult(emptyList())
            return
        }
        try {
            executor.execute {
                val result = processClipboard(clip)
                if (signature != null) {
                    lastImportedClipSignature = signature
                    lastImportedFiles = result
                }
                runOnResult(result)
            }
        } catch (e: RejectedExecutionException) {
            runOnResult(emptyList())
        }
    }

    /** 把本地明文路径写回系统剪贴板（FileProvider content URI）。 */
    fun setFilesFromPaths(paths: List<String>): Boolean {
        if (paths.isEmpty()) {
            return false
        }
        val authority = "${context.packageName}.clipflow.fileprovider"
        val files = paths.mapNotNull { path ->
            val file = File(path)
            if (file.exists() && file.isFile) file else null
        }
        if (files.isEmpty()) {
            return false
        }
        val firstUri = androidx.core.content.FileProvider.getUriForFile(context, authority, files.first())
        val clip = ClipData.newUri(context.contentResolver, "clipflow-files", firstUri)
        for (file in files.drop(1)) {
            val uri = androidx.core.content.FileProvider.getUriForFile(context, authority, file)
            clip.addItem(ClipData.Item(uri))
        }
        return try {
            val clipboard =
                context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
            clipboard.setPrimaryClip(clip)
            true
        } catch (e: Exception) {
            false
        }
    }

    fun shutdown() {
        shutDown = true
        executor.shutdown()
    }

    private fun processClipboard(clip: ClipData?): List<Map<String, Any>> {
        if (clip == null || clip.itemCount == 0) {
            return emptyList()
        }
        val items = mutableListOf<Pair<Uri, String?>>()
        for (i in 0 until clip.itemCount) {
            val item = clip.getItemAt(i)
            val uri = item.uri ?: continue
            val mimeType = clip.description.getMimeType(i) ?: context.contentResolver.getType(uri)
            if (isImageMime(mimeType)) {
                continue
            }
            items.add(Pair(uri, mimeType))
        }
        if (items.isEmpty()) {
            return emptyList()
        }

        deleteExpiredCacheFiles()
        val stamp = SimpleDateFormat("HHmmss", Locale.US).format(Date())
        val outDir = File(context.cacheDir, CACHE_DIR)
        outDir.mkdirs()
        val result = mutableListOf<Map<String, Any>>()
        for ((index, entry) in items.withIndex()) {
            val (uri, mimeType) = entry
            val displayName = queryDisplayName(uri)
            val safeName = sanitizeName(displayName)
            val outFile = File(outDir, "${stamp}_${index}_$safeName")
            val copied = copyContentUri(uri, outFile, mimeType ?: "application/octet-stream")
            result.add(copied)
        }
        return result
    }

    private fun copyContentUri(
        uri: Uri,
        outFile: File,
        fallbackMime: String
    ): Map<String, Any> {
        val displayName = queryDisplayName(uri)
        val mimeType = context.contentResolver.getType(uri) ?: fallbackMime
        val resolver: ContentResolver = context.contentResolver
        return try {
            val sourceSize = querySize(uri)
            if (sourceSize != null && sourceSize > MAX_FILE_BYTES) {
                return fileMetadata(
                    path = outFile.absolutePath,
                    name = displayName,
                    mimeType = mimeType,
                    size = sourceSize,
                    lastModified = queryLastModified(uri),
                    errorCode = "FILE_TOO_LARGE"
                )
            }
            resolver.openInputStream(uri)?.use { stream ->
                outFile.outputStream().use { output ->
                    val buffer = ByteArray(BUFFER_SIZE)
                    var total = 0L
                    while (true) {
                        val read = stream.read(buffer)
                        if (read < 0) {
                            break
                        }
                        output.write(buffer, 0, read)
                        total += read
                        if (total > MAX_FILE_BYTES) {
                            output.flush()
                            outFile.delete()
                            return fileMetadata(
                                path = outFile.absolutePath,
                                name = displayName,
                                mimeType = mimeType,
                                size = total,
                                lastModified = queryLastModified(uri),
                                errorCode = "FILE_TOO_LARGE"
                            )
                        }
                    }
                }
                fileMetadata(
                    path = outFile.absolutePath,
                    name = displayName,
                    mimeType = mimeType,
                    size = outFile.length(),
                    lastModified = queryLastModified(uri),
                    errorCode = null
                )
            } ?: fileMetadata(
                path = outFile.absolutePath,
                name = displayName,
                mimeType = mimeType,
                size = 0L,
                lastModified = queryLastModified(uri),
                errorCode = "READ_ERROR"
            )
        } catch (e: Exception) {
            outFile.delete()
            fileMetadata(
                path = outFile.absolutePath,
                name = displayName,
                mimeType = mimeType,
                size = 0L,
                lastModified = System.currentTimeMillis(),
                errorCode = "READ_ERROR"
            )
        }
    }

    private fun fileMetadata(
        path: String,
        name: String,
        mimeType: String,
        size: Long,
        lastModified: Long,
        errorCode: String?
    ): Map<String, Any> {
        val map = mutableMapOf<String, Any>(
            "path" to path,
            "name" to name,
            "mimeType" to mimeType,
            "size" to size,
            "lastModified" to lastModified,
            "temp" to true
        )
        if (errorCode != null) {
            map["errorCode"] = errorCode
        }
        return map
    }

    private fun queryDisplayName(uri: Uri): String {
        return try {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0 && !cursor.isNull(index)) {
                        cursor.getString(index)
                    } else {
                        uri.lastPathSegment ?: "file"
                    }
                } else {
                    uri.lastPathSegment ?: "file"
                }
            } ?: (uri.lastPathSegment ?: "file")
        } catch (e: Exception) {
            uri.lastPathSegment ?: "file"
        }
    }

    private fun querySize(uri: Uri): Long? {
        return try {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.SIZE),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (index >= 0 && !cursor.isNull(index)) cursor.getLong(index) else null
                } else {
                    null
                }
            } ?: null
        } catch (e: Exception) {
            null
        }
    }

    private fun queryLastModified(uri: Uri): Long {
        return try {
            context.contentResolver
                .query(uri, arrayOf("last_modified"), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst() && !cursor.isNull(0)) {
                        cursor.getLong(0)
                    } else {
                        System.currentTimeMillis()
                    }
                } ?: System.currentTimeMillis()
        } catch (e: Exception) {
            System.currentTimeMillis()
        }
    }

    private fun clipSignature(clip: ClipData?): String? {
        if (clip == null || clip.itemCount == 0) {
            return null
        }
        val builder = StringBuilder()
        for (i in 0 until clip.itemCount) {
            val item = clip.getItemAt(i)
            builder.append(item.uri?.toString() ?: "").append('|')
            builder.append(clip.description.getMimeType(i) ?: "").append(';')
        }
        return builder.toString()
    }

    private fun deleteExpiredCacheFiles() {
        val dir = File(context.cacheDir, CACHE_DIR)
        val files = dir.listFiles() ?: return
        val now = System.currentTimeMillis()
        for (file in files) {
            if (file.isFile && now - file.lastModified() > CACHE_TTL_MS) {
                file.delete()
            }
        }
    }

    companion object {
        const val MAX_FILE_BYTES = 50L * 1024 * 1024
        const val CACHE_DIR = "clipflow_file_uploads"
        private const val BUFFER_SIZE = 64 * 1024
        private const val CACHE_TTL_MS = 24L * 60 * 60 * 1000

        fun isImageMime(mimeType: String?): Boolean {
            return mimeType != null && mimeType.startsWith("image/", ignoreCase = true)
        }

        fun sanitizeName(raw: String): String {
            val allowed = StringBuilder()
            var count = 0
            for (ch in raw) {
                if (count >= 80) {
                    break
                }
                if (ch.isLetterOrDigit() || ch == '-' || ch == '_' || ch == '.') {
                    allowed.append(ch)
                    count++
                } else if (allowed.isNotEmpty() && !allowed.endsWith('_')) {
                    allowed.append('_')
                    count++
                }
            }
            var name = allowed.toString().trim('_').trim('.')
            if (name.isEmpty()) {
                name = "file"
            }
            return name
        }
    }
}
