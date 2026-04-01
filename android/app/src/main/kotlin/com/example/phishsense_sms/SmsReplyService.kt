package com.example.phishsense_sms

import android.app.Service
import android.content.Intent
import android.os.IBinder

class SmsReplyService : Service() {
    // Required for default SMS app eligibility (RESPOND_VIA_MESSAGE).
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        stopSelf()
        return START_NOT_STICKY
    }
}
