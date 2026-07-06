package com.clipflow.clipflow

import android.content.ClipboardManager
import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

class ClipboardPlugin : FlutterPlugin, MethodCallHandler, ClipboardManager.OnPrimaryClipChangedListener {
    private lateinit var channel: MethodChannel
    private var clipboardManager: ClipboardManager? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "clipflow/clipboard")
        channel.setMethodCallHandler(this)
        clipboardManager = binding.applicationContext
            .getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        clipboardManager?.removePrimaryClipChangedListener(this)
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
            else -> result.notImplemented()
        }
    }

    override fun onPrimaryClipChanged() {
        val clip = clipboardManager?.primaryClip
        if (clip != null && clip.itemCount > 0) {
            val text = clip.getItemAt(0).text
            if (text != null) {
                channel.invokeMethod("onClipboardChanged", text.toString())
            }
        }
    }
}
