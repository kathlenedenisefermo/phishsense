package com.example.phishsense_sms

import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Telephony
import android.util.Log

class SmsReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        val isDeliver = action == "android.provider.Telephony.SMS_DELIVER"
        if (action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION && !isDeliver) return

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return

        // Group multi-part SMS by originating address
        val grouped = LinkedHashMap<String, StringBuilder>()
        var timestamp = System.currentTimeMillis()

        for (sms in messages) {
            val sender = sms.originatingAddress ?: "Unknown"
            grouped.getOrPut(sender) { StringBuilder() }.append(sms.messageBody)
            if (sms.timestampMillis > 0) timestamp = sms.timestampMillis
        }

        for ((sender, body) in grouped) {
            Log.d("SmsReceiver", "SMS from $sender: ${body.take(60)}")

            val threadId = try {
                Telephony.Threads.getOrCreateThreadId(context, sender)
            } catch (e: Exception) {
                0L
            }

            // SMS_DELIVER is only sent to the default SMS app. Android requires
            // the default app to persist the message itself — the system will not.
            // Write to inbox here so readThread() can find it immediately.
            if (isDeliver) {
                try {
                    val cv = ContentValues().apply {
                        put("address", sender)
                        put("body", body.toString())
                        put("date", timestamp)
                        put("type", 1)   // 1 = inbox / received
                        put("read", 0)
                        put("seen", 0)
                        put("thread_id", threadId)
                    }
                    val insertedUri = context.contentResolver.insert(
                        Uri.parse("content://sms/inbox"), cv
                    )
                    if (insertedUri != null) {
                        Log.d("SmsReceiver", "Wrote SMS from $sender → $insertedUri (thread $threadId)")
                    } else {
                        // Insert returned null — DB write failed silently.
                        // Retry once with a fresh thread id in case the first one was stale.
                        Log.w("SmsReceiver", "Insert returned null for $sender — retrying with fresh threadId")
                        val freshThreadId = try {
                            Telephony.Threads.getOrCreateThreadId(context, sender)
                        } catch (e: Exception) { 0L }
                        cv.put("thread_id", freshThreadId)
                        val retryUri = context.contentResolver.insert(
                            Uri.parse("content://sms/inbox"), cv
                        )
                        if (retryUri != null) {
                            Log.d("SmsReceiver", "Retry succeeded → $retryUri")
                        } else {
                            Log.e("SmsReceiver", "Both inserts failed for SMS from $sender — message will not persist across reinstalls")
                        }
                    }
                } catch (e: Exception) {
                    Log.e("SmsReceiver", "Failed to write SMS to inbox: ${e.message}")
                }
            }

            // Only forward the message to Flutter once:
            //   • Default SMS app  → use SMS_DELIVER (skip SMS_RECEIVED to avoid duplicates)
            //   • Non-default app  → use SMS_RECEIVED (SMS_DELIVER never fires for non-default)
            val isDefaultApp =
                Telephony.Sms.getDefaultSmsPackage(context) == context.packageName
            val shouldForward = isDeliver || !isDefaultApp
            if (!shouldForward) continue

            val broadcast = Intent(MainActivity.SMS_ACTION).apply {
                setPackage(context.packageName)
                putExtra("sender", sender)
                putExtra("body", body.toString())
                putExtra("timestamp", timestamp)
                putExtra("threadId", threadId)
            }
            context.sendBroadcast(broadcast)
        }
    }
}
