package dev.stackchan.companion.core

import kotlinx.serialization.Serializable

const val MAX_TRUSTED_ENDPOINTS = 8

@Serializable
data class TrustedEndpointRegistryState(
    val endpoints: List<TrustedEndpoint> = emptyList(),
    val version: Int = 1,
)

class TrustedEndpointRegistry(
    initialState: TrustedEndpointRegistryState = TrustedEndpointRegistryState(),
) {
    private var state: TrustedEndpointRegistryState = initialState.normalized()

    fun snapshot(): TrustedEndpointRegistryState = state

    fun trustedEndpoints(): TrustedEndpointsResult =
        TrustedEndpointsResult(endpoints = state.endpoints)

    fun upsert(endpoint: TrustedEndpoint): TrustedEndpointRegistryState {
        require(endpoint.endpointId.isNotBlank()) { "endpoint_id is required" }
        require(endpoint.endpointKind in setOf("pc", "android")) { "unsupported endpoint_kind: ${endpoint.endpointKind}" }
        require(endpoint.publicKeyFingerprint.isBlank() || endpoint.publicKeyFingerprint.startsWith("sha256:")) {
            "public_key_fingerprint must be sha256-prefixed"
        }
        val existing = state.endpoints.filterNot { it.endpointId == endpoint.endpointId }
        require(existing.size < MAX_TRUSTED_ENDPOINTS) { "trusted endpoint registry is full" }
        state = state.copy(
            endpoints = (existing + endpoint)
                .sortedWith(compareByDescending<TrustedEndpoint> { it.priority }.thenBy { it.endpointId }),
            version = state.version + 1,
        )
        return state
    }

    fun trust(pairingResult: PairingResult): TrustedEndpointRegistryState =
        upsert(pairingResult.trustedEndpoint)

    fun forget(endpointId: String): ForgetEndpointResult {
        require(endpointId.isNotBlank()) { "endpoint_id is required" }
        val before = state.endpoints.size
        val kept = state.endpoints.filterNot { it.endpointId == endpointId }
        val removed = kept.size != before
        if (removed) {
            state = state.copy(endpoints = kept, version = state.version + 1)
        }
        return ForgetEndpointResult(endpointId = endpointId, ok = removed)
    }

    fun canAutoConnect(endpointId: String): Boolean =
        state.endpoints.any { it.endpointId == endpointId && it.autoConnect }

    fun encode(): String =
        companionJson.encodeToString(TrustedEndpointRegistryState.serializer(), state)

    companion object {
        fun decode(text: String): TrustedEndpointRegistry =
            TrustedEndpointRegistry(
                companionJson.decodeFromString(TrustedEndpointRegistryState.serializer(), text),
            )
    }
}

private fun TrustedEndpointRegistryState.normalized(): TrustedEndpointRegistryState {
    require(endpoints.size <= MAX_TRUSTED_ENDPOINTS) { "trusted endpoint registry cannot exceed $MAX_TRUSTED_ENDPOINTS entries" }
    require(endpoints.map { it.endpointId }.toSet().size == endpoints.size) { "trusted endpoint ids must be unique" }
    endpoints.forEach {
        require(it.endpointId.isNotBlank()) { "endpoint_id is required" }
        require(it.endpointKind in setOf("pc", "android")) { "unsupported endpoint_kind: ${it.endpointKind}" }
    }
    return copy(
        endpoints = endpoints.sortedWith(compareByDescending<TrustedEndpoint> { it.priority }.thenBy { it.endpointId }),
        version = maxOf(1, version),
    )
}
