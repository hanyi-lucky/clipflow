package com.clipflow.clipflow

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.PowerManager
import androidx.core.app.ActivityCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import java.io.ByteArrayOutputStream
import java.io.File

class ClipboardPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    ClipboardManager.OnPrimaryClipChangedListener {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var clipboardManager: ClipboardManager? = null
    private var activity: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "clipflow/clipboard")
        channel.setMethodCallHandler(this)
        context = binding.applicationContext
        clipboardManager = context
            .getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        clipboardManager?.removePrimaryClipChangedListener(this)
    }

    // ActivityAware
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startListening" -> {
                clipboardManager?.addPrimaryClipChangedListener(this)
                result.success(true)
            }
            "stopListening" -> {
                clipboardManager?.removePrimaryClipChangedListener(this)
                result.success(true)
            }
            "startSyncService" -> {
                val intent = Intent(context, SyncForegroundService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                result.success(true)
            }
            "stopSyncService" -> {
                val intent = Intent(context, SyncForegroundService::class.java)
                context.stopService(intent)
                result.success(true)
            }
            "updateSyncStatus" -> {
                val status = call.arguments as? String ?: "就绪"
                result.success(true)
            }
            "checkNotificationPermission" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val permission = Manifest.permission.POST_NOTIFICATIONS
                    val granted =
                        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
                    result.success(granted)
                } else {
                    result.success(true)
                }
            }
            "requestNotificationPermission" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val currentActivity = activity?.activity
                    if (currentActivity != null) {
                        ActivityCompat.requestPermissions(
                            currentActivity,
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            1001
                        )
                        result.success(true)
                    } else {
                        result.error("NO_ACTIVITY", "Activity not available", null)
                    }
                } else {
                    result.success(true)
                }
            }
            "checkBatteryOptimization" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                    val packageName = context.packageName
                    val ignoring = pm.isIgnoringBatteryOptimizations(packageName)
                    result.success(ignoring)
                } else {
                    result.success(true)
                }
            }
            "syncClipboard" -> {
                // SyncNotificationReceiver already directly invokes Flutter's
                // MethodChannel; this handler only acknowledges the call.
                result.success(true)
            }
            "hasImage" -> {
                val clip = clipboardManager?.primaryClip
                result.success(clip?.description?.hasMimeType("image/*") == true)
            }
            "getImage" -> {
                val clip = clipboardManager?.primaryClip
                if (clip == null || clip.itemCount == 0 || !clip.description.hasMimeType("image/*")) {
                    result.success(null)
                    return
                }
                val bitmap = readBitmapFromClip(clip.getItemAt(0))
                if (bitmap == null) {
                    result.success(null)
                    return
                }
                val baos = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, baos)
                result.success(
                    mapOf(
                        "bytes" to baos.toByteArray(),
                        "format" to "png",
                        "width" to bitmap.width,
                        "height" to bitmap.height
                    )
                )
            }
            "setImage" -> {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) {
                    result.error("BAD_ARGS", "bytes is required", null)
                    return
                }
                val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                if (bitmap == null) {
                    result.error("DECODE_ERROR", "cannot decode image", null)
                    return
                }
                try {
                    val authority = "${context.packageName}.clipflow.fileprovider"
                    val dir = File(context.cacheDir, "clipflow_images")
                    if (!dir.exists()) dir.mkdirs()
                    val file = File(dir, "clip_${System.currentTimeMillis()}.png")
                    file.outputStream().use { out ->
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                    }
                    val uri = FileProvider.getUriForFile(context, authority, file)
                    val clip = ClipData.newUri(context.contentResolver, "clipflow-image", uri)
                    clipboardManager?.setPrimaryClip(clip)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("CLIP_ERROR", "failed to set image clipboard: ${e.message}", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    override fun onPrimaryClipChanged() {
        val clip = clipboardManager?.primaryClip
        if (clip != null && clip.itemCount > 0) {
            val item = clip.getItemAt(0)

            // 先检测图片（image/* mime），文本分支在其后
            if (clip.description.hasMimeType("image/*")) {
                val bitmap = readBitmapFromClip(item)
                if (bitmap != null) {
                    val baos = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, baos)
                    channel.invokeMethod(
                        "onClipboardImageChanged",
                        mapOf(
                            "bytes" to baos.toByteArray(),
                            "format" to "png",
                            "width" to bitmap.width,
                            "height" to bitmap.height
                        )
                    )
                }
                return
            }

            val text = item.text
            if (text != null) {
                channel.invokeMethod("onClipboardChanged", text.toString())
            }
        }
    }

    private fun readBitmapFromClip(item: ClipData.Item): Bitmap? {
        return try {
            val uri = item.uri
            if (uri != null) {
                context.contentResolver.openInputStream(uri)?.use { stream ->
                    BitmapFactory.decodeStream(stream)
                }
            } else {
                null
            }
        } catch (e: Exception) {
            null
        }
    }
}
