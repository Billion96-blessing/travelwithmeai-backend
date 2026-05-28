package com.travelwithmeai.app

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val channelName = "travelbuddy_ai/native"
    private val logTag = "TravelBuddyVoice"
    private val microphoneRequestCode = 4107
    private var pendingMicResult: MethodChannel.Result? = null
    private var recorder: MediaRecorder? = null
    private var recordingFile: File? = null
    private var recordingStartedAt: Long = 0
    private var player: MediaPlayer? = null
    private var textToSpeech: TextToSpeech? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestMicrophonePermission" -> requestMicrophonePermission(result)
                    "startVoiceRecording" -> startVoiceRecording(result)
                    "stopVoiceRecording" -> stopVoiceRecording(result)
                    "cancelVoiceRecording" -> cancelVoiceRecording(result)
                    "playAudioBase64" -> {
                        val audioBase64 = call.argument<String>("audioBase64") ?: ""
                        val mimeType = call.argument<String>("mimeType") ?: "audio/mpeg"
                        val fallbackText = call.argument<String>("fallbackText") ?: ""
                        playAudioBase64(audioBase64, mimeType, fallbackText, result)
                    }
                    "stopPlayback" -> stopPlayback(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestMicrophonePermission(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }

        pendingMicResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            microphoneRequestCode
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == microphoneRequestCode) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingMicResult?.success(granted)
            pendingMicResult = null
        }
    }

    private fun startVoiceRecording(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            voiceLog("mic_permission_missing")
            result.error("MIC_PERMISSION", "Microphone permission is required.", null)
            return
        }

        try {
            recorder?.release()
            val outputFile = File(cacheDir, "travelbuddy_voice_${System.currentTimeMillis()}.m4a")
            val nextRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(this)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }

            nextRecorder.setAudioSource(MediaRecorder.AudioSource.MIC)
            nextRecorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            nextRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            nextRecorder.setAudioSamplingRate(16000)
            nextRecorder.setAudioEncodingBitRate(64000)
            nextRecorder.setOutputFile(outputFile.absolutePath)
            nextRecorder.prepare()
            nextRecorder.start()

            recorder = nextRecorder
            recordingFile = outputFile
            recordingStartedAt = System.currentTimeMillis()
            voiceLog("recording_started")
            result.success(true)
        } catch (error: Exception) {
            recorder?.release()
            recorder = null
            recordingFile = null
            voiceLog("recording_start_failed:${error.message}")
            result.error("RECORDING_START_FAILED", error.message, null)
        }
    }

    private fun stopVoiceRecording(result: MethodChannel.Result) {
        val activeRecorder = recorder
        val file = recordingFile

        if (activeRecorder == null || file == null) {
            result.error("NO_RECORDING", "No active recording.", null)
            return
        }

        try {
            activeRecorder.stop()
            activeRecorder.release()
            recorder = null
            recordingFile = null

            val durationMs = System.currentTimeMillis() - recordingStartedAt
            val bytes = file.readBytes()
            val encoded = Base64.encodeToString(bytes, Base64.NO_WRAP)
            file.delete()
            voiceLog("recording_stopped durationMs=$durationMs bytes=${bytes.size} header=${headerHex(bytes)}")
            result.success(
                mapOf(
                    "audioBase64" to encoded,
                    "mimeType" to "audio/mp4",
                    "durationMs" to durationMs,
                    "bytes" to bytes.size,
                    "headerHex" to headerHex(bytes)
                )
            )
        } catch (error: Exception) {
            activeRecorder.release()
            recorder = null
            recordingFile?.delete()
            recordingFile = null
            voiceLog("recording_stop_failed:${error.message}")
            result.error("RECORDING_STOP_FAILED", error.message, null)
        }
    }

    private fun cancelVoiceRecording(result: MethodChannel.Result) {
        try {
            recorder?.release()
            recordingFile?.delete()
            recorder = null
            recordingFile = null
            voiceLog("recording_cancelled")
            result.success(true)
        } catch (error: Exception) {
            voiceLog("recording_cancel_failed:${error.message}")
            result.error("RECORDING_CANCEL_FAILED", error.message, null)
        }
    }

    private fun playAudioBase64(audioBase64: String, mimeType: String, fallbackText: String, result: MethodChannel.Result) {
        if (audioBase64.isBlank()) {
            speakFallback(fallbackText, "EMPTY_AUDIO", "No audio to play.", result)
            return
        }

        try {
            stopCurrentPlayer()
            val extension = when {
                mimeType.contains("wav", ignoreCase = true) -> "wav"
                mimeType.contains("aac", ignoreCase = true) -> "aac"
                mimeType.contains("mp4", ignoreCase = true) -> "m4a"
                else -> "mp3"
            }
            val audioBytes = Base64.decode(audioBase64, Base64.DEFAULT)
            if (audioBytes.size < 512) {
                speakFallback(fallbackText, "PLAYBACK_AUDIO_TOO_SMALL", "Decoded audio is too small: ${audioBytes.size} bytes.", result)
                return
            }

            val audioFile = File(cacheDir, "travelbuddy_ai_reply_${System.currentTimeMillis()}.$extension")
            audioFile.writeBytes(audioBytes)
            voiceLog("audio_received_for_playback mime=$mimeType bytes=${audioBytes.size} header=${headerHex(audioBytes)}")

            val nextPlayer = MediaPlayer()
            var completed = false

            fun finishSuccess() {
                if (completed) return
                completed = true
                mainHandler.post {
                    voiceLog("audio_playback_ended")
                    stopCurrentPlayer()
                    audioFile.delete()
                    result.success(true)
                }
            }

            fun finishError(code: String, message: String?) {
                if (completed) return
                completed = true
                mainHandler.post {
                    voiceLog("audio_playback_failed code=$code message=$message mime=$mimeType bytes=${audioBytes.size} header=${headerHex(audioBytes)}")
                    stopCurrentPlayer()
                    audioFile.delete()
                    speakFallback(fallbackText, code, message, result)
                }
            }

            nextPlayer.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            FileInputStream(audioFile).use { stream ->
                nextPlayer.setDataSource(stream.fd)
            }
            nextPlayer.setOnPreparedListener {
                voiceLog("audio_playback_started durationMs=${it.duration} mime=$mimeType bytes=${audioBytes.size}")
                it.start()
            }
            nextPlayer.setOnCompletionListener {
                finishSuccess()
            }
            nextPlayer.setOnErrorListener { _, what, extra ->
                finishError("PLAYBACK_FAILED", "MediaPlayer error $what/$extra")
                true
            }
            player = nextPlayer
            nextPlayer.prepareAsync()
        } catch (error: Exception) {
            voiceLog("audio_playback_failed:${error.message}")
            speakFallback(fallbackText, "PLAYBACK_FAILED", error.message, result)
        }
    }

    private fun stopPlayback(result: MethodChannel.Result) {
        stopCurrentPlayer()
        voiceLog("audio_playback_stopped")
        result.success(true)
    }

    private fun stopCurrentPlayer() {
        try {
            player?.stop()
        } catch (_: Exception) {
        }
        player?.release()
        player = null
    }

    private fun speakFallback(
        text: String,
        originalCode: String,
        originalMessage: String?,
        result: MethodChannel.Result
    ) {
        val cleanText = text.trim()
        if (cleanText.isBlank()) {
            result.error(originalCode, originalMessage, null)
            return
        }

        voiceLog("android_tts_fallback_start reason=$originalCode message=$originalMessage textLength=${cleanText.length}")
        var completed = false

        fun finishSuccess() {
            if (completed) return
            completed = true
            mainHandler.post {
                voiceLog("android_tts_fallback_ended")
                result.success(true)
            }
        }

        fun finishError(message: String?) {
            if (completed) return
            completed = true
            mainHandler.post {
                voiceLog("android_tts_fallback_failed:$message")
                result.error(originalCode, "${originalMessage ?: "Playback failed"}; Android TTS fallback failed: $message", null)
            }
        }

        mainHandler.post {
            try {
                textToSpeech?.shutdown()
                textToSpeech = TextToSpeech(this) { status ->
                    if (status != TextToSpeech.SUCCESS) {
                        finishError("initialization failed")
                        return@TextToSpeech
                    }

                    val engine = textToSpeech
                    if (engine == null) {
                        finishError("engine unavailable")
                        return@TextToSpeech
                    }

                    engine.language = if (containsThai(cleanText)) Locale("th", "TH") else Locale.getDefault()
                    engine.setSpeechRate(0.96f)
                    engine.setPitch(1.0f)
                    engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                        override fun onStart(utteranceId: String?) {
                            voiceLog("android_tts_fallback_speaking")
                        }

                        override fun onDone(utteranceId: String?) {
                            engine.shutdown()
                            textToSpeech = null
                            finishSuccess()
                        }

                        @Deprecated("Deprecated in Java")
                        override fun onError(utteranceId: String?) {
                            engine.shutdown()
                            textToSpeech = null
                            finishError("speech error")
                        }

                        override fun onError(utteranceId: String?, errorCode: Int) {
                            engine.shutdown()
                            textToSpeech = null
                            finishError("speech error $errorCode")
                        }
                    })

                    val utteranceId = "travelbuddy_ai_${System.currentTimeMillis()}"
                    val speakResult = engine.speak(cleanText, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
                    if (speakResult == TextToSpeech.ERROR) {
                        engine.shutdown()
                        textToSpeech = null
                        finishError("speak returned error")
                    }
                }
            } catch (error: Exception) {
                finishError(error.message)
            }
        }
    }

    private fun voiceLog(message: String) {
        Log.i(logTag, message)
    }

    private fun headerHex(bytes: ByteArray, count: Int = 16): String {
        return bytes
            .take(count)
            .joinToString(" ") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun containsThai(text: String): Boolean {
        return text.any { it.code in 0x0E00..0x0E7F }
    }
}
