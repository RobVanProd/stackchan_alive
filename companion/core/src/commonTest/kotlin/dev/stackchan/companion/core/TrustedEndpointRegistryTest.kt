package dev.stackchan.companion.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class TrustedEndpointRegistryTest {
    @Test
    fun registryStoresPairingTrustAndListsByPriority() {
        val registry = TrustedEndpointRegistry()

        registry.upsert(endpoint("pc-studio-01", "pc", priority = 80))
        registry.upsert(endpoint("phone-rob-01", "android", priority = 60))

        val result = registry.trustedEndpoints()

        assertEquals(listOf("pc-studio-01", "phone-rob-01"), result.endpoints.map { it.endpointId })
        assertTrue(registry.canAutoConnect("pc-studio-01"))
        assertEquals(3, registry.snapshot().version)
    }

    @Test
    fun registryUpsertReplacesExistingEndpointWithoutGrowing() {
        val registry = TrustedEndpointRegistry()

        registry.upsert(endpoint("phone-rob-01", "android", priority = 60))
        registry.upsert(endpoint("phone-rob-01", "android", priority = 90, autoConnect = false))

        val endpoints = registry.snapshot().endpoints
        assertEquals(1, endpoints.size)
        assertEquals(90, endpoints.single().priority)
        assertFalse(registry.canAutoConnect("phone-rob-01"))
    }

    @Test
    fun forgetRemovesTrustAndPreventsAutoReconnect() {
        val registry = TrustedEndpointRegistry()
        registry.upsert(endpoint("phone-rob-01", "android", priority = 60))

        val result = registry.forget("phone-rob-01")

        assertTrue(result.ok)
        assertFalse(registry.canAutoConnect("phone-rob-01"))
        assertTrue(registry.snapshot().endpoints.isEmpty())
    }

    @Test
    fun forgetReportsMissingEndpointWithoutVersionChange() {
        val registry = TrustedEndpointRegistry()

        val result = registry.forget("missing")

        assertFalse(result.ok)
        assertEquals(1, registry.snapshot().version)
    }

    @Test
    fun registryEnforcesEightEndpointLimit() {
        val registry = TrustedEndpointRegistry()
        repeat(MAX_TRUSTED_ENDPOINTS) { index ->
            registry.upsert(endpoint("endpoint-$index", if (index % 2 == 0) "pc" else "android", priority = index))
        }

        assertFailsWith<IllegalArgumentException> {
            registry.upsert(endpoint("endpoint-overflow", "pc", priority = 1))
        }
    }

    @Test
    fun registryRoundTripsJsonState() {
        val registry = TrustedEndpointRegistry()
        registry.upsert(endpoint("pc-studio-01", "pc", priority = 80))

        val decoded = TrustedEndpointRegistry.decode(registry.encode())

        assertEquals(registry.snapshot(), decoded.snapshot())
    }

    @Test
    fun registryRejectsDuplicateInitialState() {
        assertFailsWith<IllegalArgumentException> {
            TrustedEndpointRegistry(
                TrustedEndpointRegistryState(
                    endpoints = listOf(
                        endpoint("phone-rob-01", "android"),
                        endpoint("phone-rob-01", "android"),
                    ),
                ),
            )
        }
    }

    private fun endpoint(
        id: String,
        kind: String,
        priority: Int = 50,
        autoConnect: Boolean = true,
    ): TrustedEndpoint =
        TrustedEndpoint(
            endpointId = id,
            endpointName = id,
            endpointKind = kind,
            publicKeyFingerprint = "sha256:1111222233334444",
            priority = priority,
            autoConnect = autoConnect,
            capabilities = listOf("settings", "diagnostics"),
            lastSeenMs = 0,
        )
}
