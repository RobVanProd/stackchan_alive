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
        assertEquals("offline", released.state)
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
    fun explicitLowerPriorityClaimCanReplaceHigherPriorityOwner() {
        val coordinator = BrainOwnerCoordinator(
            registryWith(
                phoneEndpoint(priority = 80),
                studioEndpoint(priority = 60),
            ),
        )
        coordinator.claim(ClaimBrain(endpointId = "phone-rob-01", reason = "active mobile brain"))

        val response = assertIs<OwnerStatus>(
            coordinator.claim(ClaimBrain(endpointId = "studio-mac-01", reason = "manual takeover")),
        )

        assertEquals("studio-mac-01", response.activeBrainOwner)
        assertEquals("claimed", response.state)
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
        assertEquals("offline", coordinator.status().state)
    }

    @Test
    fun expiredOwnerPromotesHighestPriorityHealthyEndpoint() {
        var nowMs = 1_000L
        val coordinator = BrainOwnerCoordinator(
            trustedEndpointRegistry = registryWith(
                phoneEndpoint(priority = 60),
                studioEndpoint(priority = 90),
            ),
            clockMs = { nowMs },
            ownerLeaseMs = 5_000,
        )
        coordinator.claim(ClaimBrain(endpointId = "studio-mac-01", reason = "primary PC"))
        nowMs = 3_000L
        coordinator.heartbeat("phone-rob-01")
        nowMs = 7_000L

        val status = coordinator.status()

        assertEquals("phone-rob-01", status.activeBrainOwner)
        assertEquals("promoted", status.state)
        assertEquals(1, status.ownerExpirations)
        assertEquals(1, status.ownerPromotions)
    }

    @Test
    fun expiredOwnerFallsOfflineWhenNoHealthyOwnerCapableEndpointExists() {
        var nowMs = 1_000L
        val coordinator = BrainOwnerCoordinator(
            trustedEndpointRegistry = registryWith(
                studioEndpoint(priority = 90),
                phoneEndpoint(priority = 100, capabilities = listOf("settings")),
            ),
            clockMs = { nowMs },
            ownerLeaseMs = 5_000,
        )
        coordinator.claim(ClaimBrain(endpointId = "studio-mac-01", reason = "primary PC"))
        nowMs = 3_000L
        coordinator.heartbeat("phone-rob-01")
        nowMs = 7_000L

        val status = coordinator.status()

        assertEquals("", status.activeBrainOwner)
        assertEquals("offline", status.state)
        assertEquals(1, status.ownerExpirations)
        assertEquals(0, status.ownerPromotions)
    }

    @Test
    fun heartbeatFromUntrustedEndpointIsRejected() {
        val coordinator = BrainOwnerCoordinator(registryWith(phoneEndpoint()))

        val response = assertIs<BridgeError>(coordinator.heartbeat("unknown-phone"))

        assertEquals("owner_untrusted_endpoint", response.code)
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
