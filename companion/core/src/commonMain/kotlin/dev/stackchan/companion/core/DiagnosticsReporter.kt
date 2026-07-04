package dev.stackchan.companion.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class DiagnosticsReporter(
    private val settingsRepository: SettingsRepository = SettingsRepository(),
    private val trustedEndpointRegistry: TrustedEndpointRegistry = TrustedEndpointRegistry(),
    private val brainOwnerCoordinator: BrainOwnerCoordinator = BrainOwnerCoordinator(trustedEndpointRegistry),
    private val bridgeMode: String = "companion",
) {
    fun snapshot(request: DiagnosticsRequest = DiagnosticsRequest(domains = emptyList())): DiagnosticsSnapshot {
        val domains = normalizeDomains(request.domains)
        return DiagnosticsSnapshot(
            bridge = bridgeDiagnostics(),
            audio = optionalDomain("audio", domains) { audioDiagnostics() },
            model = optionalDomain("model", domains) { modelDiagnostics() },
            firmware = optionalDomain("firmware", domains) { firmwareDiagnostics() },
            battery = optionalDomain("battery", domains) { batteryDiagnostics() },
        )
    }

    private fun bridgeDiagnostics(): JsonObject {
        val owner = brainOwnerCoordinator.status()
        return buildJsonObject {
            put("protocol", JsonPrimitive(CompanionIdentity.protocol))
            put("app_version", JsonPrimitive(CompanionIdentity.appVersion))
            put("mode", JsonPrimitive(bridgeMode))
            put("settings_version", JsonPrimitive(settingsRepository.snapshot().version))
            put("trusted_endpoint_count", JsonPrimitive(trustedEndpointRegistry.snapshot().endpoints.size))
            put("active_brain_owner", JsonPrimitive(owner.activeBrainOwner))
            put("owner_kind", JsonPrimitive(owner.ownerKind))
            put("owner_state", JsonPrimitive(owner.state))
        }
    }

    private fun audioDiagnostics(): JsonObject =
        buildJsonObject {
            put("engine", JsonPrimitive("fake"))
            put("input_sample_rate", JsonPrimitive(16000))
            put("output_sample_rate", JsonPrimitive(24000))
            put("supports_binary_audio", JsonPrimitive(true))
            put("wake_gate", settingsPrimitive("privacy", "wake_gate", fallback = true))
        }

    private fun modelDiagnostics(): JsonObject =
        buildJsonObject {
            val modelSettings = settingsRepository.snapshot(listOf("model")).settings["model"]!!.jsonObject
            put("profile", modelSettings["profile"] ?: JsonPrimitive("fake"))
            put("runner_status", modelSettings["runner_status"] ?: JsonPrimitive("deterministic_fake"))
        }

    private fun firmwareDiagnostics(): JsonObject =
        buildJsonObject {
            put("target", JsonPrimitive("stackchan_alive"))
            put("robot_attached", JsonPrimitive(false))
            put("transport", JsonPrimitive("websocket"))
        }

    private fun batteryDiagnostics(): JsonObject =
        buildJsonObject {
            put("present", JsonPrimitive(false))
            put("source", JsonPrimitive("companion_host"))
        }

    private fun settingsPrimitive(domain: String, key: String, fallback: Boolean): JsonPrimitive {
        val domainSettings = settingsRepository.snapshot(listOf(domain)).settings[domain]?.jsonObject
        return domainSettings?.get(key)?.jsonPrimitive ?: JsonPrimitive(fallback)
    }

    private fun normalizeDomains(domains: List<String>): Set<String> {
        val requested = domains.map { it.trim() }.filter { it.isNotEmpty() }.toSet()
        val allowed = setOf("bridge", "audio", "model", "firmware", "battery")
        require(requested.all { it in allowed }) { "unknown diagnostics domain" }
        return requested
    }

    private fun optionalDomain(
        domain: String,
        requested: Set<String>,
        build: () -> JsonObject,
    ): JsonObject? =
        if (requested.isEmpty() || domain in requested) build() else null
}
