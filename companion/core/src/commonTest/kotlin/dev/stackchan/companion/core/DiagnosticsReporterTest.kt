package dev.stackchan.companion.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class DiagnosticsReporterTest {
    @Test
    fun diagnosticsSnapshotIncludesBridgeAndDefaultDomains() {
        val settings = SettingsRepository()
        settings.set(
            expectedVersion = 1,
            patch = buildJsonObject {
                put("model", buildJsonObject {
                    put("profile", JsonPrimitive("test-fake"))
                })
            },
        )
        val registry = TrustedEndpointRegistry()
        registry.upsert(
            TrustedEndpoint(
                endpointId = "phone-rob-01",
                endpointKind = "android",
                publicKeyFingerprint = "sha256:1111222233334444",
                capabilities = listOf("brain_owner"),
            ),
        )
        val coordinator = BrainOwnerCoordinator(registry)
        coordinator.claim(ClaimBrain(endpointId = "phone-rob-01", reason = "diagnostics test"))
        val reporter = DiagnosticsReporter(
            settingsRepository = settings,
            trustedEndpointRegistry = registry,
            brainOwnerCoordinator = coordinator,
        )

        val snapshot = reporter.snapshot()

        assertEquals("stackchan.bridge.v1", snapshot.bridge["protocol"]!!.jsonPrimitive.content)
        assertEquals(2, snapshot.bridge["settings_version"]!!.jsonPrimitive.content.toInt())
        assertEquals(1, snapshot.bridge["trusted_endpoint_count"]!!.jsonPrimitive.content.toInt())
        assertEquals("phone-rob-01", snapshot.bridge["active_brain_owner"]!!.jsonPrimitive.content)
        assertEquals("fake", snapshot.audio!!.jsonObject["engine"]!!.jsonPrimitive.content)
        assertEquals("test-fake", snapshot.model!!.jsonObject["profile"]!!.jsonPrimitive.content)
        assertEquals("stackchan_alive", snapshot.firmware!!.jsonObject["target"]!!.jsonPrimitive.content)
        assertEquals(false, snapshot.battery!!.jsonObject["present"]!!.jsonPrimitive.content.toBoolean())
    }

    @Test
    fun diagnosticsSnapshotCanSelectOptionalDomains() {
        val snapshot = DiagnosticsReporter().snapshot(DiagnosticsRequest(domains = listOf("model")))

        assertEquals("fake", snapshot.model!!.jsonObject["profile"]!!.jsonPrimitive.content)
        assertEquals(null, snapshot.audio)
        assertEquals(null, snapshot.firmware)
        assertEquals(null, snapshot.battery)
    }

    @Test
    fun diagnosticsSnapshotRejectsUnknownDomains() {
        assertFailsWith<IllegalArgumentException> {
            DiagnosticsReporter().snapshot(DiagnosticsRequest(domains = listOf("unknown")))
        }
    }
}
