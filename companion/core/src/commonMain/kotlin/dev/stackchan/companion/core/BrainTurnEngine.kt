package dev.stackchan.companion.core

enum class BrainTurnSource {
    APP_TEXT,
    ROBOT_AUDIO,
}

data class BrainTurnRequest(
    val seq: Int,
    val text: String,
    val source: BrainTurnSource,
    val audioBytesReceived: Int = 0,
    val inputSampleRate: Int = 0,
    val deviceId: String = "",
    val activeBrainOwner: String? = null,
)

data class BrainTurnResponse(
    val text: String,
    val intent: String,
    val arousal: Double = 0.42,
    val valence: Double = 0.64,
    val audioPcm16: ByteArray? = null,
    val audioSampleRate: Int = 24000,
)

fun interface BrainTurnEngine {
    suspend fun respond(request: BrainTurnRequest): BrainTurnResponse
}

object DeterministicBrainTurnEngine : BrainTurnEngine {
    override suspend fun respond(request: BrainTurnRequest): BrainTurnResponse =
        BrainTurnResponse(
            text = request.text.ifBlank {
                if (request.source == BrainTurnSource.ROBOT_AUDIO) {
                    "Fake audio turn received ${request.audioBytesReceived} bytes at ${request.inputSampleRate}Hz."
                } else {
                    "Text turn received."
                }
            },
            intent = when (request.source) {
                BrainTurnSource.APP_TEXT -> "app_text_turn"
                BrainTurnSource.ROBOT_AUDIO -> "fake_audio_turn"
            },
        )
}
