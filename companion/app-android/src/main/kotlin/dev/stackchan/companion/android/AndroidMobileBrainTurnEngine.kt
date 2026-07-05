package dev.stackchan.companion.android

import dev.stackchan.companion.core.BrainTurnEngine
import dev.stackchan.companion.core.BrainTurnRequest
import dev.stackchan.companion.core.BrainTurnResponse
import dev.stackchan.companion.core.DeterministicBrainTurnEngine

internal fun androidBrainTurnEngine(status: AndroidModelAssetStatus): BrainTurnEngine =
    if (status.loaded) {
        StagedGemmaBrainTurnEngine(status)
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
