package dev.stackchan.companion.core

class BrainOwnerCoordinator(
    private val trustedEndpointRegistry: TrustedEndpointRegistry,
) {
    private var activeEndpointId: String = ""

    fun status(state: String = if (activeEndpointId.isBlank()) "idle" else "active"): OwnerStatus {
        val endpoint = activeEndpoint()
        return OwnerStatus(
            activeBrainOwner = endpoint?.endpointId.orEmpty(),
            ownerKind = endpoint?.endpointKind ?: "none",
            state = if (endpoint == null) "idle" else state,
        )
    }

    fun claim(message: ClaimBrain): BridgeMessage {
        val candidate = trustedEndpoint(message.endpointId)
            ?: return BridgeError(
                code = "owner_untrusted_endpoint",
                detail = "Brain owner claims require a trusted endpoint.",
                recoverable = true,
            )
        if ("brain_owner" !in candidate.capabilities) {
            return BridgeError(
                code = "owner_capability_missing",
                detail = "Trusted endpoint is not allowed to own the brain.",
                recoverable = true,
            )
        }
        val current = activeEndpoint()
        if (current != null && current.endpointId != candidate.endpointId && candidate.priority < current.priority) {
            return BridgeError(
                code = "owner_priority_conflict",
                detail = "Active brain owner has higher priority.",
                recoverable = true,
            )
        }

        activeEndpointId = candidate.endpointId
        return status(state = "claimed")
    }

    fun release(message: ReleaseBrain): BridgeMessage {
        val endpoint = trustedEndpoint(message.endpointId)
            ?: return BridgeError(
                code = "owner_untrusted_endpoint",
                detail = "Brain owner release requires a trusted endpoint.",
                recoverable = true,
            )
        if ("brain_owner" !in endpoint.capabilities) {
            return BridgeError(
                code = "owner_capability_missing",
                detail = "Trusted endpoint is not allowed to own the brain.",
                recoverable = true,
            )
        }
        if (activeEndpointId.isBlank()) {
            return status()
        }
        if (activeEndpointId != endpoint.endpointId) {
            return BridgeError(
                code = "owner_not_active",
                detail = "Only the active brain owner can release ownership.",
                recoverable = true,
            )
        }

        activeEndpointId = ""
        return status()
    }

    fun clearIfForgotten(endpointId: String) {
        if (activeEndpointId == endpointId) {
            activeEndpointId = ""
        }
    }

    private fun activeEndpoint(): TrustedEndpoint? =
        trustedEndpoint(activeEndpointId)

    private fun trustedEndpoint(endpointId: String): TrustedEndpoint? =
        trustedEndpointRegistry.snapshot().endpoints.firstOrNull { it.endpointId == endpointId }
}
