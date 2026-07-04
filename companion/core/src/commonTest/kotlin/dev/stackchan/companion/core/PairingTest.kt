package dev.stackchan.companion.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

class PairingTest {
    @Test
    fun pairingConfirmationCreatesTrustedEndpoint() {
        val challenge = createPairingChallenge(
            endpoint = sampleEndpoint(),
            shortCode = "7k-9p q2",
            publicKeyFingerprint = "SHA256:AA BB CC DD EE FF 0011",
        )

        val result = confirmPairing(
            challenge,
            PairingConfirmation(
                enteredShortCode = "7K9PQ2",
                displayedFingerprint = "sha256:aabbccddeeff0011",
                priority = 80,
                autoConnect = true,
            ),
        )

        assertEquals("7K9PQ2", challenge.shortCode)
        assertEquals("sha256:aabbccddeeff0011", challenge.publicKeyFingerprint)
        assertEquals("phone-rob-01", result.trustedEndpoint.endpointId)
        assertEquals("Rob's Phone", result.trustedEndpoint.endpointName)
        assertEquals("android", result.trustedEndpoint.endpointKind)
        assertEquals(80, result.trustedEndpoint.priority)
        assertEquals(listOf("settings", "persona_select"), result.trustedEndpoint.capabilities)
        assertEquals(DiscoveryMethod.MANUAL, result.method)
    }

    @Test
    fun pairingRejectsWrongShortCode() {
        val challenge = createPairingChallenge(sampleEndpoint(), "ABC123", "sha256:1111222233334444")

        assertFailsWith<IllegalArgumentException> {
            confirmPairing(
                challenge,
                PairingConfirmation(
                    enteredShortCode = "ABC124",
                    displayedFingerprint = "sha256:1111222233334444",
                ),
            )
        }
    }

    @Test
    fun pairingRejectsWrongFingerprint() {
        val challenge = createPairingChallenge(sampleEndpoint(), "ABC123", "sha256:1111222233334444")

        assertFailsWith<IllegalArgumentException> {
            confirmPairing(
                challenge,
                PairingConfirmation(
                    enteredShortCode = "ABC123",
                    displayedFingerprint = "sha256:9999222233334444",
                ),
            )
        }
    }

    @Test
    fun pairingRejectsBadChallengeInputs() {
        assertFailsWith<IllegalArgumentException> {
            createPairingChallenge(sampleEndpoint(), "12345", "sha256:1111222233334444")
        }
        assertFailsWith<IllegalArgumentException> {
            createPairingChallenge(sampleEndpoint(), "ABC123", "not-a-fingerprint")
        }
        assertFailsWith<IllegalArgumentException> {
            createPairingChallenge(sampleEndpoint(protocol = "stackchan.bridge.v2"), "ABC123", "sha256:1111222233334444")
        }
    }

    @Test
    fun pairingCanDisableAutoConnectForManualTrust() {
        val challenge = createPairingChallenge(sampleEndpoint(), "ABC123", "sha256:1111222233334444")
        val result = confirmPairing(
            challenge,
            PairingConfirmation(
                enteredShortCode = "abc 123",
                displayedFingerprint = "11:11:22:22:33:33:44:44",
                priority = 20,
                autoConnect = false,
            ),
        )

        assertFalse(result.trustedEndpoint.autoConnect)
        assertEquals(20, result.trustedEndpoint.priority)
    }

    private fun sampleEndpoint(protocol: String = CompanionIdentity.protocol): DiscoveredEndpoint =
        DiscoveredEndpoint(
            endpointId = "phone-rob-01",
            endpointName = "Rob's Phone",
            endpointKind = "android",
            host = "192.168.1.50",
            port = DEFAULT_BRIDGE_PORT,
            protocol = protocol,
            capabilities = listOf("settings", "persona_select"),
            method = DiscoveryMethod.MANUAL,
        )
}
