package com.example.phishsense_sms

import android.app.Activity
import android.app.PendingIntent
import android.app.role.RoleManager
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.provider.Settings
import android.provider.Telephony
import android.telephony.SmsManager
import android.util.Log
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : FlutterActivity() {

    companion object {
        const val SMS_ACTION = "com.phishsense.SMS_RECEIVED"
        const val SMS_SENT_ACTION = "com.phishsense.SMS_SENT"
        const val REQUEST_ROLE_SMS = 1001
        var eventSink: EventChannel.EventSink? = null
        var sentStatusSink: EventChannel.EventSink? = null
        var sentPendingId = 0
    }

    private lateinit var inference: PhishingInference
    private var smsReceiver: BroadcastReceiver? = null
    private var sentReceiver: BroadcastReceiver? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var roleRequestPending = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        inference = PhishingInference(applicationContext)
        NotificationHelper.createChannels(this)
        CoroutineScope(Dispatchers.IO).launch {
            try {
                inference.initialize()
                Log.d("MainActivity", "Inference engine initialized.")
            } catch (e: Exception) {
                Log.e("MainActivity", "Failed to initialize inference: ${e.message}")
            }
        }

        // ── EventChannel: real-time incoming SMS ──────────────────────────
        // Register the internal broadcast receiver once here so it is never
        // torn down when Flutter re-subscribes to the EventChannel (which
        // would call onCancel then onListen and drop messages in between).
        val smsFilter = IntentFilter(SMS_ACTION)
        smsReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val sender    = intent.getStringExtra("sender") ?: "Unknown"
                val body      = intent.getStringExtra("body") ?: ""
                val timestamp = intent.getLongExtra("timestamp", System.currentTimeMillis())
                val threadId  = intent.getLongExtra("threadId", 0L)

                // Classify on IO thread, then post a notification with the result.
                CoroutineScope(Dispatchers.IO).launch {
                    val prediction = try {
                        inference.classify(body)
                    } catch (e: Exception) {
                        Log.e("MainActivity", "Notification classify failed: ${e.message}")
                        mapOf("label" to "legitimate", "confidence" to 0.0)
                    }
                    val isPhishing = (prediction["label"] as? String) == "phishing"
                    val confidence = (prediction["confidence"] as? Double) ?: 0.0
                    val notifId    = (sender + timestamp).hashCode()
                    NotificationHelper.post(
                        applicationContext, sender, body, isPhishing, confidence, notifId
                    )
                }

                // Forward to Flutter as before.
                val data = mapOf(
                    "sender" to sender, "body" to body,
                    "timestamp" to timestamp, "threadId" to threadId
                )
                mainHandler.post { eventSink?.success(data) }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(smsReceiver, smsFilter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(smsReceiver, smsFilter)
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.phishsense/sms_stream")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        // ── EventChannel: SMS sent-status (success / failure) ─────────────
        val sentFilter = IntentFilter(SMS_SENT_ACTION)
        sentReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                // Only fire once per message (on the last part)
                if (!intent.getBooleanExtra("isLastPart", true)) return
                val to        = intent.getStringExtra("to") ?: ""
                val body      = intent.getStringExtra("body") ?: ""
                val timestamp = intent.getLongExtra("timestamp", 0L)
                if (resultCode != Activity.RESULT_OK) {
                    val data = mapOf(
                        "to"        to to,
                        "body"      to body,
                        "timestamp" to timestamp,
                        "success"   to false,
                        "errorCode" to resultCode
                    )
                    mainHandler.post { sentStatusSink?.success(data) }
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(sentReceiver, sentFilter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(sentReceiver, sentFilter)
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.phishsense/sms_sent_status")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sentStatusSink = events
                }
                override fun onCancel(arguments: Any?) {
                    sentStatusSink = null
                }
            })

        // ── MethodChannel: ML inference ───────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.phishsense/inference")
            .setMethodCallHandler { call, result ->
                if (call.method == "getModelVersion") {
                    result.success(PhishingInference.MODEL_VERSION)
                } else if (call.method == "classifySms") {
                    val text = call.argument<String>("text") ?: ""
                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val prediction = inference.classify(text)
                            withContext(Dispatchers.Main) { result.success(prediction) }
                        } catch (e: Exception) {
                            Log.e("MainActivity", "Classification error: ${e.message}")
                            withContext(Dispatchers.Main) {
                                result.success(mapOf("label" to "legitimate", "confidence" to 0.0))
                            }
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }

        // ── MethodChannel: SMS management ─────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.phishsense/sms_manager")
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "isDefaultSmsApp" -> {
                        val isDefault = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            val roleManager = getSystemService(RoleManager::class.java)
                            roleManager.isRoleHeld(RoleManager.ROLE_SMS)
                        } else {
                            @Suppress("DEPRECATION")
                            Telephony.Sms.getDefaultSmsPackage(this) == packageName
                        }
                        result.success(isDefault)
                    }

                    "requestDefaultSmsApp" -> {
                        Log.e("PHISHSENSE", "requestDefaultSmsApp: called, SDK=${Build.VERSION.SDK_INT}, pkg=$packageName")
                        result.success(null)
                        mainHandler.postDelayed({
                            roleRequestPending = true
                            launchDefaultSmsRequest()
                        }, 200)
                    }

                    "readInbox" -> {
                        val limit = call.argument<Int>("limit") ?: 500
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val messages = readAllMessages(limit)
                                withContext(Dispatchers.Main) { result.success(messages) }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) {
                                    result.error("READ_FAILED", e.message, null)
                                }
                            }
                        }
                    }

                    "readThread" -> {
                        val threadId = (call.argument<Int>("threadId") ?: 0).toLong()
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val messages = readThreadMessages(threadId)
                                withContext(Dispatchers.Main) { result.success(messages) }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) {
                                    result.error("READ_FAILED", e.message, null)
                                }
                            }
                        }
                    }

                    "sendSms" -> {
                        val to = call.argument<String>("to") ?: ""
                        val body = call.argument<String>("body") ?: ""
                        try {
                            val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                getSystemService(SmsManager::class.java)
                            } else {
                                @Suppress("DEPRECATION")
                                SmsManager.getDefault()
                            }
                            val parts = smsManager.divideMessage(body)
                            val timestamp = System.currentTimeMillis()

                            // Build a PendingIntent per part so we can detect send failure
                            val sentIntents = ArrayList<PendingIntent>(parts.size)
                            for (i in parts.indices) {
                                val si = Intent(SMS_SENT_ACTION).apply {
                                    setPackage(packageName)
                                    putExtra("to", to)
                                    putExtra("body", body)
                                    putExtra("timestamp", timestamp)
                                    putExtra("isLastPart", i == parts.size - 1)
                                }
                                sentIntents.add(
                                    PendingIntent.getBroadcast(
                                        this@MainActivity,
                                        sentPendingId++,
                                        si,
                                        PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
                                    )
                                )
                            }

                            smsManager.sendMultipartTextMessage(to, null, parts, sentIntents, null)

                            val cv = ContentValues().apply {
                                put("address", to)
                                put("body", body)
                                put("type", 2) // sent
                                put("date", timestamp)
                                put("read", 1)
                            }
                            contentResolver.insert(Uri.parse("content://sms/sent"), cv)

                            result.success(null)
                        } catch (e: Exception) {
                            result.error("SEND_FAILED", e.message, null)
                        }
                    }

                    "openDefaultAppsSettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS))
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("FAILED", e.message, null)
                        }
                    }

                    "lookupContactName" -> {
                        val number = call.argument<String>("number") ?: ""
                        CoroutineScope(Dispatchers.IO).launch {
                            val name = lookupContact(number)
                            withContext(Dispatchers.Main) { result.success(name) }
                        }
                    }

                    "makeCall" -> {
                        val number = call.argument<String>("number") ?: ""
                        try {
                            val intent = Intent(Intent.ACTION_CALL, Uri.parse("tel:$number"))
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("CALL_FAILED", e.message, null)
                        }
                    }

                    "deleteThread" -> {
                        val threadId = (call.argument<Int>("threadId") ?: 0).toLong()
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val uri = Uri.parse("content://sms/conversations/$threadId")
                                val deleted = contentResolver.delete(uri, null, null)
                                withContext(Dispatchers.Main) { result.success(deleted) }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) { result.error("DELETE_FAILED", e.message, null) }
                            }
                        }
                    }

                    "deleteMessage" -> {
                        val id = (call.argument<Int>("id") ?: 0).toLong()
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val uri = Uri.parse("content://sms/$id")
                                val deleted = contentResolver.delete(uri, null, null)
                                withContext(Dispatchers.Main) { result.success(deleted) }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) { result.error("DELETE_FAILED", e.message, null) }
                            }
                        }
                    }

                    "markThreadRead" -> {
                        val threadId = (call.argument<Int>("threadId") ?: 0).toLong()
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val values = ContentValues().apply { put("read", 1) }
                                contentResolver.update(
                                    Uri.parse("content://sms"),
                                    values,
                                    "thread_id = ? AND read = 0",
                                    arrayOf(threadId.toString())
                                )
                                withContext(Dispatchers.Main) { result.success(null) }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) { result.success(null) }
                            }
                        }
                    }

                    "getUnreadCounts" -> {
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val counts = getUnreadCounts()
                                withContext(Dispatchers.Main) { result.success(counts) }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) { result.success(mapOf<String, Int>()) }
                            }
                        }
                    }

                    "searchMessages" -> {
                        val query = call.argument<String>("query") ?: ""
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val messages = searchSmsMessages(query)
                                withContext(Dispatchers.Main) { result.success(messages) }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) { result.error("SEARCH_FAILED", e.message, null) }
                            }
                        }
                    }

                    "getAllContacts" -> {
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val contacts = getAllContacts()
                                withContext(Dispatchers.Main) { result.success(contacts) }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) { result.success(listOf<Map<String, String>>()) }
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun launchDefaultSmsRequest(): Boolean {
        // Approach 1 — RoleManager (Android 10 / API 29+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val roleManager = getSystemService(RoleManager::class.java)
                Log.e("PHISHSENSE", "RoleManager available=${roleManager != null}, roleAvailable=${roleManager?.isRoleAvailable(RoleManager.ROLE_SMS)}, roleHeld=${roleManager?.isRoleHeld(RoleManager.ROLE_SMS)}")
                if (roleManager != null && roleManager.isRoleAvailable(RoleManager.ROLE_SMS)) {
                    startActivityForResult(roleManager.createRequestRoleIntent(RoleManager.ROLE_SMS), REQUEST_ROLE_SMS)
                    Log.e("PHISHSENSE", "Approach 1 (RoleManager) launched OK")
                    return true
                }
            } catch (e: Exception) {
                Log.e("PHISHSENSE", "Approach 1 failed: ${e.javaClass.simpleName}: ${e.message}")
            }
        }

        // Approach 2 — ACTION_CHANGE_DEFAULT (Android 8–9)
        try {
            @Suppress("DEPRECATION")
            val intent = Intent(Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT)
            intent.putExtra(Telephony.Sms.Intents.EXTRA_PACKAGE_NAME, packageName)
            startActivity(intent)
            Log.e("PHISHSENSE", "Approach 2 (ACTION_CHANGE_DEFAULT) launched OK")
            return true
        } catch (e: Exception) {
            Log.e("PHISHSENSE", "Approach 2 failed: ${e.javaClass.simpleName}: ${e.message}")
        }

        // Approach 3 — Open Default Apps settings
        try {
            startActivity(Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS))
            Log.e("PHISHSENSE", "Approach 3 (Default Apps Settings) launched OK")
            return true
        } catch (e: Exception) {
            Log.e("PHISHSENSE", "Approach 3 failed: ${e.javaClass.simpleName}: ${e.message}")
        }

        // Approach 4 — Open this app's settings as last resort
        try {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
            })
            Log.e("PHISHSENSE", "Approach 4 (App Settings) launched OK")
            return true
        } catch (e: Exception) {
            Log.e("PHISHSENSE", "Approach 4 failed: ${e.javaClass.simpleName}: ${e.message}")
        }

        return false
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_ROLE_SMS) {
            roleRequestPending = false
            Log.e("PHISHSENSE", "onActivityResult: resultCode=$resultCode (OK=${RESULT_OK})")
            if (resultCode != RESULT_OK) {
                // Samsung (and some other OEMs) silently cancel the role dialog.
                // Fall back to Default Apps settings so the user can set it manually.
                Log.e("PHISHSENSE", "Role dialog suppressed — opening Default Apps Settings as fallback")
                mainHandler.postDelayed({
                    try {
                        startActivity(Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS))
                    } catch (e: Exception) {
                        Log.e("PHISHSENSE", "Default Apps Settings fallback failed: ${e.message}")
                    }
                }, 100)
            }
        }
    }

    private fun readAllMessages(limit: Int): List<Map<String, Any?>> {
        val messages = mutableListOf<Map<String, Any?>>()
        val uri = Uri.parse("content://sms")
        val cursor = contentResolver.query(
            uri,
            arrayOf("_id", "address", "body", "date", "type", "thread_id", "read"),
            null, null,
            "date DESC"
        ) ?: return messages
        cursor.use {
            var count = 0
            while (it.moveToNext() && count < limit) {
                messages.add(
                    mapOf(
                        "id" to it.getLong(it.getColumnIndexOrThrow("_id")),
                        "sender" to (it.getString(it.getColumnIndexOrThrow("address")) ?: "Unknown"),
                        "body" to (it.getString(it.getColumnIndexOrThrow("body")) ?: ""),
                        "timestamp" to it.getLong(it.getColumnIndexOrThrow("date")),
                        "isOutgoing" to (it.getInt(it.getColumnIndexOrThrow("type")) == 2),
                        "threadId" to it.getLong(it.getColumnIndexOrThrow("thread_id")),
                        "isRead" to (it.getInt(it.getColumnIndexOrThrow("read")) == 1)
                    )
                )
                count++
            }
        }
        return messages
    }

    private fun readThreadMessages(threadId: Long): List<Map<String, Any?>> {
        val messages = mutableListOf<Map<String, Any?>>()
        val uri = Uri.parse("content://sms")
        val cursor = contentResolver.query(
            uri,
            arrayOf("_id", "address", "body", "date", "type", "thread_id", "read"),
            "thread_id = ?",
            arrayOf(threadId.toString()),
            "date ASC"
        ) ?: return messages
        cursor.use {
            while (it.moveToNext()) {
                messages.add(
                    mapOf(
                        "id" to it.getLong(it.getColumnIndexOrThrow("_id")),
                        "sender" to (it.getString(it.getColumnIndexOrThrow("address")) ?: "Unknown"),
                        "body" to (it.getString(it.getColumnIndexOrThrow("body")) ?: ""),
                        "timestamp" to it.getLong(it.getColumnIndexOrThrow("date")),
                        "isOutgoing" to (it.getInt(it.getColumnIndexOrThrow("type")) == 2),
                        "threadId" to it.getLong(it.getColumnIndexOrThrow("thread_id")),
                        "isRead" to (it.getInt(it.getColumnIndexOrThrow("read")) == 1)
                    )
                )
            }
        }
        return messages
    }

    private fun lookupContact(phoneNumber: String): String? {
        val uri = ContactsContract.PhoneLookup.CONTENT_FILTER_URI.buildUpon()
            .appendPath(phoneNumber).build()
        val cursor = contentResolver.query(
            uri,
            arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
            null, null, null
        ) ?: return null
        return cursor.use { if (it.moveToFirst()) it.getString(0) else null }
    }

    private fun getUnreadCounts(): Map<String, Int> {
        val counts = mutableMapOf<String, Int>()
        val cursor = contentResolver.query(
            Uri.parse("content://sms/inbox"),
            arrayOf("thread_id"),
            "read = 0",
            null, null
        ) ?: return counts
        cursor.use {
            while (it.moveToNext()) {
                val tid = it.getLong(it.getColumnIndexOrThrow("thread_id")).toString()
                counts[tid] = (counts[tid] ?: 0) + 1
            }
        }
        return counts
    }

    private fun searchSmsMessages(query: String): List<Map<String, Any?>> {
        val messages = mutableListOf<Map<String, Any?>>()
        if (query.isBlank()) return messages
        val cursor = contentResolver.query(
            Uri.parse("content://sms"),
            arrayOf("_id", "address", "body", "date", "type", "thread_id"),
            "body LIKE ? OR address LIKE ?",
            arrayOf("%$query%", "%$query%"),
            "date DESC"
        ) ?: return messages
        cursor.use {
            var count = 0
            while (it.moveToNext() && count < 100) {
                messages.add(mapOf(
                    "id" to it.getLong(it.getColumnIndexOrThrow("_id")),
                    "threadId" to it.getLong(it.getColumnIndexOrThrow("thread_id")),
                    "sender" to (it.getString(it.getColumnIndexOrThrow("address")) ?: "Unknown"),
                    "body" to (it.getString(it.getColumnIndexOrThrow("body")) ?: ""),
                    "timestamp" to it.getLong(it.getColumnIndexOrThrow("date")),
                    "isOutgoing" to (it.getInt(it.getColumnIndexOrThrow("type")) == 2)
                ))
                count++
            }
        }
        return messages
    }

    private fun getAllContacts(): List<Map<String, String>> {
        val contacts = mutableListOf<Map<String, String>>()
        val cursor = contentResolver.query(
            android.provider.ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(
                android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER
            ),
            null, null,
            "${android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC"
        ) ?: return contacts
        cursor.use {
            while (it.moveToNext()) {
                val name = it.getString(0) ?: return@use
                val number = it.getString(1) ?: return@use
                contacts.add(mapOf("name" to name, "number" to number))
            }
        }
        return contacts
    }

    override fun onDestroy() {
        smsReceiver?.let { unregisterReceiver(it) }
        sentReceiver?.let { unregisterReceiver(it) }
        super.onDestroy()
    }
}
