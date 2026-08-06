package com.clipflow.clipflow

import android.app.*
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class SyncForegroundService : Service() {
    companion object {
        const val NOTIFICATION_ID = 1
        const val CHANNEL_ID = "clipflow_sync_channel"
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("就绪"))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val status = intent?.getStringExtra("status") ?: "就绪"
        updateNotification(status)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "ClipFlow 同步",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "ClipFlow 剪切板同步服务"
                setShowBadge(false)
                enableVibration(false)
                enableLights(false)
                setSound(null, null)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(status: String): Notification {
        // 整条通知点击 → 打开 App → onResume 触发 triggerSync()
        // 「立即同步」按钮与整条点击共用 getActivity 拉起路径（不同 requestCode）：
        // Android 10+ 禁止后台启动 Activity，广播（getBroadcast）是历史「点击无效果」的根源，
        // 因此这里不使用广播，只用 getActivity（通知 Action 属用户可见交互，不受后台启动限制）。
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        }
        // 整条通知点击：打开 App（requestCode 0）
        val openPendingIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        // 「立即同步」按钮：同样拉起 App，前台 onResume 触发一次同步（requestCode 1 与整条区分）
        val syncNowPendingIntent = PendingIntent.getActivity(
            this, 1, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("ClipFlow 同步")
            .setContentText(status)
            .setSmallIcon(android.R.drawable.ic_popup_sync)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(openPendingIntent)  // Click notification to open app
            .addAction(
                android.R.drawable.ic_popup_sync,
                "立即同步",
                syncNowPendingIntent
            )
            .build()
    }

    fun updateNotification(status: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(status))
    }
}
