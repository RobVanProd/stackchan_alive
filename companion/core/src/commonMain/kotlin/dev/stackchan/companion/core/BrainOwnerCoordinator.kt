package dev.stackchan.companion.core

import kotlin.time.TimeSource

const val DEFAULT_BRAIN_OWNER_LEASE_MS: Long = 15_000

private fun monotonicClockMs(): () -> Long {
    val origin = TimeSource.Monotonic.markNow()
    return { origin.elapsedNow().inWholeMilliseconds }
}

class BrainOwnerCoordinator(
    private val trustedEndpointRegistry: TrustedEndpointRegistry,
    private val clockMs: () -> Long = monotonicClockMs(),
    private val ownerLeaseMs: Long = DEFAULT_BRAIN_OWNER_LEASE_MS,
) {
    private var activeEndpointId: String = ""
    private val lastSeenMs = mutableMapOf<String, Long>()
    private var ownerExpirations: Int = 0
    private var ownerPromotions: Int = 0

    init {
        require(ownerLeaseMs >= 1_000) { "ownerLeaseMs must be at least 1000" }
    }

    fun status(state: String? = null): OwnerStatus {
        val resolvedState = state ?: reconcileOwner()
        val endpoint = activeEndpoint()
        return OwnerStatus(
            activeBrainOwner = endpoint?.endpointId.orEmpty(),
            ownerKind = endpoint?.endpointKind ?: "none",
            state = if (endpoint == null) "offline" else resolvedState,
            ownerLeaseMs = ownerLeaseMs,
            ownerExpirations = ownerExpirations,
            ownerPromotions = ownerPromotions,
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
        markSeen(candidate.endpointId)
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

        markSeen(endpoint.endpointId)
        activeEndpointId = ""
        val promoted = promoteBestEndpoint(exclude = endpoint.endpointId)
        if (promoted) {
            ownerPromotions += 1
        }
        return status(state = if (promoted) "promoted" else "released")
    }

    fun heartbeat(endpointId: String): BridgeMessage {
        val endpoint = trustedEndpoint(endpointId)
            ?: return BridgeError(
                code = "owner_untrusted_endpoint",
                detail = "Endpoint heartbeat requires a trusted endpoint.",
                recoverable = true,
            )
        markSeen(endpoint.endpointId)
        return status()
    }

    fun clearIfForgotten(endpointId: String) {
        lastSeenMs.remove(endpointId)
        if (activeEndpointId == endpointId) {
            activeEndpointId = ""
            if (promoteBestEndpoint(exclude = endpointId)) {
                ownerPromotions += 1
            }
        }
    }

    private fun reconcileOwner(): String {
        val activeId = activeEndpointId
        val active = activeEndpoint()
        if (active != null && "brain_owner" in active.capabilities && isHealthy(active.endpointId)) {
            return "active"
        }
        if (activeId.isNotBlank()) {
            ownerExpirations += 1
        }
        activeEndpointId = ""
        if (promoteBestEndpoint(exclude = activeId)) {
            ownerPromotions += 1
            return "promoted"
        }
        return "offline"
    }

    private fun promoteBestEndpoint(exclude: String): Boolean {
        val candidate = trustedEndpointRegistry.snapshot().endpoints
            .asSequence()
            .filter { it.endpointId != exclude }
            .filter { it.autoConnect }
            .filter { "brain_owner" in it.capabilities }
            .filter { isHealthy(it.endpointId) }
            .maxWithOrNull(
                compareBy<TrustedEndpoint> { it.priority }
                    .thenBy { lastSeenMs[it.endpointId] ?: Long.MIN_VALUE },
            )
            ?: return false
        activeEndpointId = candidate.endpointId
        return true
    }

    private fun markSeen(endpointId: String) {
        lastSeenMs[endpointId] = clockMs()
    }

    private fun isHealthy(endpointId: String): Boolean {
        val seenAt = lastSeenMs[endpointId] ?: return false
        return (clockMs() - seenAt).coerceAtLeast(0) <= ownerLeaseMs
    }

    private fun activeEndpoint(): TrustedEndpoint? =
        trustedEndpoint(activeEndpointId)

    private fun trustedEndpoint(endpointId: String): TrustedEndpoint? =
        trustedEndpointRegistry.snapshot().endpoints.firstOrNull { it.endpointId == endpointId }
}
