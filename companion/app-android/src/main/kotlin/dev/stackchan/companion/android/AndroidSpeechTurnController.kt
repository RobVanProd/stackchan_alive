package dev.stackchan.companion.android

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import java.util.Locale

class AndroidSpeechTurnController(
    private val context: Context,
) {
    private var recognizer: SpeechRecognizer? = null

    fun isAvailable(): Boolean =
        SpeechRecognizer.isRecognitionAvailable(context)

    fun start(
        onListening: () -> Unit,
        onPartialTranscript: (String) -> Unit,
        onFinalTranscript: (String) -> Unit,
        onError: (String) -> Unit,
    ) {
        stop()
        if (!isAvailable()) {
            onError("Android speech recognition is not available on this device.")
            return
        }
        val speechRecognizer = SpeechRecognizer.createSpeechRecognizer(context).also {
            recognizer = it
        }
        speechRecognizer.setRecognitionListener(
            object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {
                    onListening()
                }

                override fun onBeginningOfSpeech() = Unit
                override fun onRmsChanged(rmsdB: Float) = Unit
                override fun onBufferReceived(buffer: ByteArray?) = Unit
                override fun onEndOfSpeech() = Unit

                override fun onError(error: Int) {
                    val message = speechErrorMessage(error)
                    stop()
                    onError(message)
                }

                override fun onResults(results: Bundle?) {
                    val transcript = bestTranscript(results)
                    stop()
                    if (transcript.isBlank()) {
                        onError("No speech transcript was returned.")
                    } else {
                        onFinalTranscript(transcript)
                    }
                }

                override fun onPartialResults(partialResults: Bundle?) {
                    val transcript = bestTranscript(partialResults)
                    if (transcript.isNotBlank()) {
                        onPartialTranscript(transcript)
                    }
                }

                override fun onEvent(eventType: Int, params: Bundle?) = Unit
            },
        )
        speechRecognizer.startListening(speechIntent())
    }

    fun stop() {
        recognizer?.runCatching {
            stopListening()
            cancel()
            destroy()
        }
        recognizer = null
    }

    private fun speechIntent(): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        }

    private fun bestTranscript(results: Bundle?): String =
        results
            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull()
            ?.trim()
            .orEmpty()

    private fun speechErrorMessage(error: Int): String =
        when (error) {
            SpeechRecognizer.ERROR_AUDIO -> "Microphone audio failed."
            SpeechRecognizer.ERROR_CLIENT -> "Speech recognizer stopped before a transcript was available."
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission is required for push-to-talk."
            SpeechRecognizer.ERROR_NETWORK -> "Speech recognition network error."
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Speech recognition network timed out."
            SpeechRecognizer.ERROR_NO_MATCH -> "No speech was recognized."
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Speech recognizer is busy. Try again."
            SpeechRecognizer.ERROR_SERVER -> "Speech recognition service error."
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech was heard."
            else -> "Speech recognition failed with error $error."
        }
}
