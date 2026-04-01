package com.example.phishsense_sms

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color

object NotificationHelper {

    private const val CHANNEL_PHISHING = "phishing_alerts"
    private const val CHANNEL_SMS      = "incoming_sms"

    /** Call once at app start to register both notification channels. */
    fun createChannels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)

        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_PHISHING,
                "Phishing Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description      = "Alerts for messages detected as phishing"
                enableLights(true)
                lightColor       = Color.RED
                enableVibration(true)
            }
        )

        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_SMS,
                "Incoming Messages",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Notifications for safe incoming messages"
            }
        )
    }

    /**
     * Post a notification for an incoming SMS.
     *
     * @param sender      display name or phone number
     * @param body        full message text
     * @param isPhishing  true if the ML model flagged this as phishing
     * @param confidence  model confidence in [0,1]
     * @param notifId     unique id (use a hash of sender+timestamp)
     */
    fun post(
        context: Context,
        sender: String,
        body: String,
        isPhishing: Boolean,
        confidence: Double,
        notifId: Int,
    ) {
        val nm = context.getSystemService(NotificationManager::class.java)

        // Tapping the notification opens the app.
        val openIntent = PendingIntent.getActivity(
            context,
            notifId,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val channelId   = if (isPhishing) CHANNEL_PHISHING else CHANNEL_SMS
        val labelText   = if (isPhishing) "⚠️  Phishing Detected" else "✅  Safe"
        val accentColor = if (isPhishing) Color.rgb(242, 85, 79) else Color.rgb(6, 200, 94)
        val preview     = if (body.length > 120) body.take(120) + "…" else body

        // setColorized(true) fills the notification background with accentColor,
        // making it look like the colored label badges used inside the app.
        val builder = Notification.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setSubText(sender)           // sender name in the header line
            .setContentTitle(labelText)   // "Phishing Detected" / "Safe" as the banner
            .setContentText(preview)
            .setStyle(Notification.BigTextStyle().bigText(preview))
            .setColor(accentColor)
            .setColorized(true)
            .setContentIntent(openIntent)
            .setAutoCancel(true)
            .setShowWhen(true)
            .setWhen(System.currentTimeMillis())

        nm.notify(notifId, builder.build())
    }
}
