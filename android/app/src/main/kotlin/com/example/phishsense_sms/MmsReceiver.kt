package com.example.phishsense_sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class MmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // Required for default SMS app eligibility.
        Log.d("MmsReceiver", "MMS received.")
    }
}
