package com.clipflow.clipflow

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class SyncNotificationReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "SyncReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(TAG, "onReceive called, action: ${intent.action}")
        if (intent.action == SyncForegroundService.ACTION_SYNC_NOW) {
            // Android 10+ restricts clipboard access for background apps
            // Solution: Launch app to foreground, onResume will trigger syncClipboard()
            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            }
            if (launchIntent != null) {
                Log.d(TAG, "Launching app to foreground")
                context.startActivity(launchIntent)
            } else {
                Log.e(TAG, "Could not get launch intent")
            }
        }
    }
}
