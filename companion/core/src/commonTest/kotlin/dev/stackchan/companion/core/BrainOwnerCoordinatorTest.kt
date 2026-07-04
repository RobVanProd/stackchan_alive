package dev.stackchan.companion.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

class BrainOwnerCoordinatorTest {
    @Test
    fun trustedEndpointCanClaimAndReleaseBrainOwnership() {
        val coordinator = BrainOwnerCoordinator(registryWith(phoneEndpoint()))

        val claimed = assertIs<OwnerStatus>(
            coordinator.claim(ClaimBrain(endpointId = "phone-rob-01", reason = "primary mobile brain")),
        )
        val released = assertIs<OwnerStatus>(
            coordinator.release(ReleaseBrain(endpointId = "phone-rob-01", reason = "handoff complete")),
        )

        assertEquals("phone-rob-01", claimed.activeBrainOwner)
        assertEquals("android", claimed.ownerKind)
        assertEquals("claimed", claimed.state)
        assertEquals("", released.activeBrainOwner)
        assertEquals("none", released.ownerKind)
        assertEquals("idle", released.state)
    }

    @Test
    fun untrustedEndpointCannotClaimOwnership() {
        val coordinator = BrainOwnerCoordinator(TrustedEndpointRegistry())

        val response = assertIs<BridgeError>(
            coordinator.claim(ClaimBrain(endpointId = "unknown-phone", reason = "spoof")),
        )

        assertEquals("owner_untrusted_endpoint", response.code)
    }

    @Test
    fun trustedEndpointWithoutBrainOwnerCapabilityCannotClaimOwnership() {
        val coordinator = BrainOwnerCoordinator(
            registryWith(
                phoneEndpoint(capabilities = listOf("settings")),
            ),
        )

        val response = assertIs<BridgeError>(
            coordinator.claim(ClaimBrain(endpointId = "phone-rob-01", reason = "settings-only endpoint")),
        )

        assertEquals("owner_capability_missing", response.code)
    }

    @Test
    fun lowerPriorityEndpointCannotPreemptHigherPriorityOwner() {
        val coordinator = BrainOwnerCoordinator(
            registryWith(
                phoneEndpoint(priority = 80),
                studioEndpoint(priority = 60),
            ),
        )
        coordinator.claim(ClaimBrain(endpointId = "phone-rob-01", reason = "active mobile brain"))

        val response = assertIs<BridgeError>(
            coordinator.claim(ClaimBrain(endpointId = "studio-mac-01", reason = "manual takeover")),
        )

        assertEquals("owner_priority_conflict", response.code)
        assertEquals("phone-rob-01", coordinator.status().activeBrainOwner)
    }

    @Test
    fun equalOrHigherPriorityEndpointCanTakeOver() {
        val coordinator = BrainOwnerCoordinator(
            registryWith(
                phoneEndpoint(priority = 80),
                studioEndpoint(priority = 90),
            ),
        )
        coordinator.claim(ClaimBrain(endpointId = "phone-rob-01", reason = "active mobile brain"))

        val response = assertIs<OwnerStatus>(
            coordinator.claim(ClaimBrain(endpointId = "studio-mac-01", reason = "operator handoff")),
        )

        assertEquals("studio-mac-01", response.activeBrainOwner)
        assertEquals("pc", response.ownerKind)
        assertEquals("claimed", response.state)
    }

    @Test
    fun forgottenActiveOwnerClearsStatus() {
        val coordinator = BrainOwnerCoordinator(registryWith(phoneEndpoint()))
        coordinator.claim(ClaimBrain(endpointId = "phone-rob-01", reason = "active mobile brain"))

        coordinator.clearIfForgotten("phone-rob-01")

        assertEquals("", coordinator.status().activeBrainOwner)
        assertEquals("idle", coordinator.status().state)
    }

    private fun registryWith(vararg endpoints: TrustedEndpoint): TrustedEndpointRegistry {
        val registry = TrustedEndpointRegistry()
        endpoints.forEach { registry.upsert(it) }
        return registry
    }

    private fun phoneEndpoint(
        priority: Int = 80,
        capabilities: List<String> = listOf("settings", "brain_owner"),
    ): TrustedEndpoint =
        TrustedEndpoint(
            endpointId = "phone-rob-01",
            endpointName = "Rob's Phone",
            endpointKind = "android",
            publicKeyFingerprint = "sha256:1111222233334444",
            priority = priority,
            autoConnect = true,
            capabilities = capabilities,
        )

    private fun studioEndpoint(priority: Int): TrustedEndpoint =
        TrustedEndpoint(
            endpointId = "studio-mac-01",
            endpointName = "Studio Mac",
            endpointKind = "pc",
            publicKeyFingerprint = "sha256:aaaabbbbccccdddd",
            priority = priority,
            autoConnect = true,
            capabilities = listOf("settings", "brain_owner"),
        )
}
