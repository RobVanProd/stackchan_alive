package dev.stackchan.companion.android

import android.content.Context
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.LogSeverity
import com.google.ai.edge.litertlm.SamplerConfig
import dev.stackchan.companion.core.BrainTurnEngine
import dev.stackchan.companion.core.BrainTurnRequest
import dev.stackchan.companion.core.BrainTurnResponse
import dev.stackchan.companion.core.DeterministicBrainTurnEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal fun androidBrainTurnEngine(status: AndroidModelAssetStatus): BrainTurnEngine =
    if (status.loaded) {
        StagedGemmaBrainTurnEngine(status)
    } else {
        DeterministicBrainTurnEngine
    }

internal fun androidBrainTurnEngine(context: Context, status: AndroidModelAssetStatus): BrainTurnEngine =
    if (status.loaded) {
        LiteRtGemmaBrainTurnEngine(context.applicationContext, status)
    } else {
        DeterministicBrainTurnEngine
    }

private class StagedGemmaBrainTurnEngine(
    private val status: AndroidModelAssetStatus,
) : BrainTurnEngine {
    override suspend fun respond(request: BrainTurnRequest): BrainTurnResponse =
        BrainTurnResponse(
            text = "Gemma-4-E2B asset is staged at ${status.localPath}, but LiteRT runtime inference is not validated on this device yet. I heard: ${request.text.ifBlank { "audio turn" }}",
            intent = "mobile_brain_staged_pending_litert",
            arousal = 0.38,
            valence = 0.52,
        )
}

private class LiteRtGemmaBrainTurnEngine(
    context: Context,
    private val status: AndroidModelAssetStatus,
) : BrainTurnEngine {
    private val cacheDir = context.cacheDir.resolve("litertlm").absolutePath

    override suspend fun respond(request: BrainTurnRequest): BrainTurnResponse =
        withContext(Dispatchers.Default) {
            runCatching { generateText(request) }
                .fold(
                    onSuccess = { text ->
                        BrainTurnResponse(
                            text = text.ifBlank { "I heard you." },
                            intent = "mobile_brain_litert_turn",
                            arousal = 0.46,
                            valence = 0.62,
                        )
                    },
                    onFailure = { error ->
                        BrainTurnResponse(
                            text = litertFailureText(error, request),
                            intent = "mobile_brain_litert_error",
                            arousal = 0.32,
                            valence = 0.42,
                        )
                    },
                )
        }

    private fun generateText(request: BrainTurnRequest): String {
        Engine.setNativeMinLogSeverity(LogSeverity.ERROR)
        val gpuAttempt = runCatching { generateTextWithBackend(request, Backend.GPU()) }
        return gpuAttempt.getOrElse { generateTextWithBackend(request, Backend.CPU()) }
    }

    private fun generateTextWithBackend(request: BrainTurnRequest, backend: Backend): String {
        val engineConfig = EngineConfig(
            modelPath = status.localPath,
            backend = backend,
            cacheDir = cacheDir,
        )
        Engine(engineConfig).use { engine ->
            engine.initialize()
            engine.createConversation(stackchanConversationConfig()).use { conversation ->
                return conversation.sendMessage(stackchanPrompt(request)).contents.contents
                    .mapNotNull { (it as? Content.Text)?.text }
                    .joinToString(separator = "")
                    .trim()
            }
        }
    }

    private fun stackchanConversationConfig(): ConversationConfig =
        ConversationConfig(
            systemInstruction = Contents.of(
                "You are Stack-chan Alive, a small local companion robot. Reply with brief speech for the robot face and speaker. Stay friendly, concrete, and safe. Do not use markdown.",
            ),
            samplerConfig = SamplerConfig(
                topK = 40,
                topP = 0.9,
                temperature = 0.7,
            ),
        )

    private fun stackchanPrompt(request: BrainTurnRequest): String =
        buildString {
            append("User turn source: ")
            append(request.source.name)
            append('\n')
            if (request.audioBytesReceived > 0) {
                append("Audio bytes received: ")
                append(request.audioBytesReceived)
                append(" at ")
                append(request.inputSampleRate)
                append("Hz\n")
            }
            append("User said: ")
            append(request.text.ifBlank { "Respond to the latest audio turn." })
        }

    private fun litertFailureText(error: Throwable, request: BrainTurnRequest): String =
        "Gemma-4-E2B asset is staged at ${status.localPath}, but LiteRT runtime inference failed " +
            "on this device: ${error::class.simpleName}. I heard: ${request.text.ifBlank { "audio turn" }}"
}
