package com.example.phishsense_sms

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.util.JsonReader
import android.util.Log
import java.io.File
import java.io.InputStreamReader
import java.nio.LongBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.exp

class PhishingInference(private val context: Context) {

    companion object {
        const val MODEL_VERSION = "1.0.0"
        // How long classify() waits for the model before giving up.
        // 120 s covers slow devices / first-run cache copy.
        private const val INIT_TIMEOUT_SEC = 120L
    }

    private var env: OrtEnvironment? = null
    private var session: OrtSession? = null

    // Counts down to 0 exactly once — either when init succeeds, or when it
    // throws. Using finally guarantees classify() is never blocked forever.
    private val readyLatch = CountDownLatch(1)
    @Volatile private var initFailed = false

    // token string → log probability
    private val vocabLogProb = HashMap<String, Float>(300_000)
    // token string → id
    private val vocabId = HashMap<String, Int>(300_000)

    private val maxLength = 128
    private val bosId = 0L
    private val eosId = 2L
    private val unkId = 3L
    private val padId = 1L

    fun initialize() {
        try {
            loadModel()
            loadVocab()
            Log.d("PhishingInference", "Model ready.")
        } catch (e: Exception) {
            Log.e("PhishingInference", "Initialization failed: ${e.message}", e)
            initFailed = true
        } finally {
            // Always release, so classify() never hangs indefinitely.
            readyLatch.countDown()
        }
    }

    private fun loadModel() {
        val modelFile = File(context.cacheDir, "phishsense_model.onnx")
        val prefs = context.getSharedPreferences("phishsense_prefs", Context.MODE_PRIVATE)

        // Use the asset file size as a change detector — no manual version bump needed.
        // Replacing the ml/ folder with a new model will (virtually always) change the size.
        val assetSize = context.assets.openFd("ml/phishsense_model.onnx").use { it.length }
        val cachedSize = prefs.getLong("model_asset_size", -1L)

        // Re-copy from assets if: file missing, empty, or asset size changed.
        if (!modelFile.exists() || modelFile.length() == 0L || cachedSize != assetSize) {
            modelFile.delete()
            context.assets.open("ml/phishsense_model.onnx").use { input ->
                modelFile.outputStream().use { output -> input.copyTo(output) }
            }
            prefs.edit().putLong("model_asset_size", assetSize).apply()
            Log.d("PhishingInference", "Model updated — asset size ${assetSize}B, cached ${modelFile.length()}B.")
        }

        env = OrtEnvironment.getEnvironment()
        // BASIC_OPT skips the expensive graph optimisations that can stall
        // on emulators / devices with limited userfaultfd support.
        val opts = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(2)
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.BASIC_OPT)
        }
        try {
            session = env!!.createSession(modelFile.absolutePath, opts)
            Log.d("PhishingInference", "ORT session created.")
        } catch (e: Exception) {
            // Cached file may be corrupt — delete so next launch re-copies.
            modelFile.delete()
            Log.e("PhishingInference", "createSession failed, cache deleted: ${e.message}")
            throw e
        }
    }

    private fun loadVocab() {
        Log.d("PhishingInference", "Loading vocab…")
        context.assets.open("ml/tokenizer.json").use { stream ->
            val reader = JsonReader(InputStreamReader(stream, Charsets.UTF_8))
            reader.use {
                // Navigate: root object → "model" → "vocab" array
                reader.beginObject()
                while (reader.hasNext()) {
                    val name = reader.nextName()
                    if (name == "model") {
                        reader.beginObject()
                        while (reader.hasNext()) {
                            val fieldName = reader.nextName()
                            if (fieldName == "vocab") {
                                reader.beginArray()
                                var id = 0
                                while (reader.hasNext()) {
                                    reader.beginArray()
                                    val token = reader.nextString()
                                    val logProb = reader.nextDouble().toFloat()
                                    reader.endArray()
                                    vocabLogProb[token] = logProb
                                    vocabId[token] = id
                                    id++
                                }
                                reader.endArray()
                            } else {
                                reader.skipValue()
                            }
                        }
                        reader.endObject()
                    } else {
                        reader.skipValue()
                    }
                }
                reader.endObject()
            }
        }
        Log.d("PhishingInference", "Vocab loaded: ${vocabId.size} tokens.")
    }

    fun classify(text: String): Map<String, Any> {
        // Wait for initialize() to finish (success or failure).
        if (!readyLatch.await(INIT_TIMEOUT_SEC, TimeUnit.SECONDS)) {
            Log.w("PhishingInference", "Model not ready after ${INIT_TIMEOUT_SEC}s — skipping.")
            return safeDefault()
        }
        // Initialize completed but threw an exception.
        if (initFailed) return safeDefault()

        val env = this.env ?: return safeDefault()
        val session = this.session ?: return safeDefault()

        val tokenIds = tokenize(text)
        val shape = longArrayOf(1, tokenIds.size.toLong())
        val attentionMask = LongArray(tokenIds.size) { 1L }

        val idsTensor = OnnxTensor.createTensor(env, LongBuffer.wrap(tokenIds), shape)
        val maskTensor = OnnxTensor.createTensor(env, LongBuffer.wrap(attentionMask), shape)

        val inputs = mapOf("input_ids" to idsTensor, "attention_mask" to maskTensor)
        val result = session.run(inputs)

        return try {
            @Suppress("UNCHECKED_CAST")
            val logits = (result[0].value as Array<FloatArray>)[0]
            val probs = softmax(logits)
            val label = if (probs[1] > probs[0]) "phishing" else "legitimate"
            val confidence = if (probs[1] > probs[0]) probs[1] else probs[0]
            mapOf("label" to label, "confidence" to confidence.toDouble())
        } finally {
            idsTensor.close()
            maskTensor.close()
            result.close()
        }
    }

    private fun tokenize(text: String): LongArray {
        // Normalizer: strip trailing whitespace; collapse runs of whitespace to a single space
        val normalized = text.trimEnd().replace(Regex("\\s+"), " ").trim()

        // Pre-tokenizer: WhitespaceSplit then Metaspace (prepend_scheme: always)
        // Split on all Unicode whitespace — SMS messages often contain \n
        val words = normalized.split(Regex("\\s+")).filter { it.isNotEmpty() }
        val tokenIds = mutableListOf<Long>()

        for (word in words) {
            val prefixed = "\u2581$word"
            val ids = viterbiSegment(prefixed)
            tokenIds.addAll(ids)
        }

        // Apply template: BOS + tokens (truncated) + EOS
        val maxContent = maxLength - 2
        val truncated = if (tokenIds.size > maxContent) tokenIds.subList(0, maxContent) else tokenIds
        val result = LongArray(truncated.size + 2)
        result[0] = bosId
        for (i in truncated.indices) result[i + 1] = truncated[i].toLong()
        result[result.size - 1] = eosId
        return result
    }

    private fun viterbiSegment(word: String): List<Long> {
        val n = word.length
        // best[i] = best log-prob to reach position i
        val best = FloatArray(n + 1) { Float.NEGATIVE_INFINITY }
        val back = IntArray(n + 1) { -1 }
        best[0] = 0f

        for (end in 1..n) {
            for (start in 0 until end) {
                if (best[start] == Float.NEGATIVE_INFINITY) continue
                val sub = word.substring(start, end)
                val lp = vocabLogProb[sub]
                if (lp != null) {
                    val score = best[start] + lp
                    if (score > best[end]) {
                        best[end] = score
                        back[end] = start
                    }
                }
            }
        }

        // If no path found, return unk
        if (best[n] == Float.NEGATIVE_INFINITY) return listOf(unkId)

        // Backtrack
        val segments = mutableListOf<String>()
        var pos = n
        while (pos > 0) {
            val start = back[pos]
            segments.add(word.substring(start, pos))
            pos = start
        }
        segments.reverse()
        return segments.map { vocabId[it]?.toLong() ?: unkId }
    }

    private fun softmax(logits: FloatArray): FloatArray {
        val max = logits.max()
        val exps = FloatArray(logits.size) { exp((logits[it] - max).toDouble()).toFloat() }
        val sum = exps.sum()
        return FloatArray(exps.size) { exps[it] / sum }
    }

    private fun safeDefault() = mapOf("label" to "legitimate", "confidence" to 0.0)
}
