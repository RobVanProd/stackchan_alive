package dev.stackchan.companion.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject

val settingsDomains = setOf(
    "persona",
    "voice",
    "motion",
    "display",
    "bridge",
    "privacy",
    "model",
    "diagnostics",
)

private val lockedSettingPaths = setOf(
    "motion.servo_enabled",
    "motion.safe_stop",
    "motion.center_offsets",
    "bridge.active_owner",
    "privacy.wake_gate",
    "privacy.raw_audio_retention",
    "privacy.memory_reset",
)

data class SettingsSetOutcome(
    val result: SettingsResult,
    val errorCode: String = "",
    val rejectedPaths: List<String> = emptyList(),
)

@Serializable
data class SettingsRepositoryState(
    val version: Int = 1,
    val settings: JsonObject = defaultSettings(),
)

class SettingsRepository(
    initialSettings: JsonObject = defaultSettings(),
    initialVersion: Int = 1,
) {
    private var version = maxOf(1, initialVersion)
    private var settings = normalizeSettings(initialSettings)

    fun snapshot(domains: List<String> = settingsDomains.toList()): SettingsSnapshot {
        val requested = normalizeDomains(domains)
        return SettingsSnapshot(
            version = version,
            settings = JsonObject(settings.filterKeys { it in requested }),
        )
    }

    fun handleGet(message: SettingsGet): SettingsSnapshot =
        snapshot(message.domains)

    fun handleSet(message: SettingsSet): SettingsSetOutcome =
        set(message.version, message.settings)

    fun snapshotState(): SettingsRepositoryState =
        SettingsRepositoryState(version = version, settings = settings)

    fun encode(): String =
        companionJson.encodeToString(SettingsRepositoryState.serializer(), snapshotState())

    fun set(expectedVersion: Int, patch: JsonObject): SettingsSetOutcome {
        val normalizedPatch = normalizeSettings(patch)
        val rejected = lockedPathsIn(normalizedPatch)
        if (rejected.isNotEmpty()) {
            return SettingsSetOutcome(
                result = SettingsResult(ok = false, version = version),
                errorCode = "settings_locked",
                rejectedPaths = rejected,
            )
        }
        if (expectedVersion != version) {
            return SettingsSetOutcome(
                result = SettingsResult(ok = false, version = version),
                errorCode = "version_conflict",
            )
        }

        settings = deepMerge(settings, normalizedPatch)
        version += 1
        return SettingsSetOutcome(SettingsResult(ok = true, version = version))
    }

    private fun normalizeDomains(domains: List<String>): Set<String> {
        val requested = domains.map { it.trim() }.filter { it.isNotEmpty() }.toSet()
        val normalized = if (requested.isEmpty()) settingsDomains else requested
        require(normalized.all { it in settingsDomains }) { "unknown settings domain" }
        return normalized
    }

    companion object {
        fun decode(text: String): SettingsRepository {
            val state = companionJson.decodeFromString(SettingsRepositoryState.serializer(), text).normalized()
            return SettingsRepository(initialSettings = state.settings, initialVersion = state.version)
        }
    }
}

fun defaultSettings(): JsonObject = buildJsonObject {
    put("persona", buildJsonObject {
        put("active", JsonPrimitive("spark"))
    })
    put("voice", buildJsonObject {
        put("profile", JsonPrimitive("review_synth"))
        put("volume", JsonPrimitive(70))
    })
    put("motion", buildJsonObject {
        put("servo_enabled", JsonPrimitive(false))
        put("reduced_motion", JsonPrimitive(false))
        put("safe_stop", JsonPrimitive(false))
    })
    put("display", buildJsonObject {
        put("brightness", JsonPrimitive(80))
        put("reduced_motion", JsonPrimitive(false))
        put("preview_mode", JsonPrimitive(false))
    })
    put("bridge", buildJsonObject {
        put("preferred_mode_policy", JsonPrimitive("auto"))
        put("active_owner", JsonPrimitive(""))
    })
    put("privacy", buildJsonObject {
        put("wake_gate", JsonPrimitive(true))
        put("raw_audio_retention", JsonPrimitive("none"))
        put("export_logs", JsonPrimitive(false))
    })
    put("model", buildJsonObject {
        put("profile", JsonPrimitive("fake"))
        put("runner_status", JsonPrimitive("deterministic_fake"))
    })
    put("diagnostics", buildJsonObject {
        put("exportable", JsonPrimitive(true))
    })
}

private fun normalizeSettings(value: JsonObject): JsonObject {
    require(value.keys.all { it in settingsDomains }) { "unknown settings domain" }
    value.forEach { (domain, element) ->
        require(element is JsonObject) { "settings domain must be an object: $domain" }
    }
    return value
}

private fun SettingsRepositoryState.normalized(): SettingsRepositoryState =
    copy(
        version = maxOf(1, version),
        settings = deepMerge(defaultSettings(), normalizeSettings(settings)),
    )

private fun lockedPathsIn(patch: JsonObject): List<String> =
    patch.flatMap { (domain, element) ->
        if (element !is JsonObject) {
            emptyList()
        } else {
            element.keys.map { "$domain.$it" }.filter { it in lockedSettingPaths }
        }
    }.sorted()

private fun deepMerge(base: JsonObject, patch: JsonObject): JsonObject {
    val merged = base.toMutableMap()
    patch.forEach { (key, patchValue) ->
        val baseValue: JsonElement? = merged[key]
        merged[key] = if (baseValue is JsonObject && patchValue is JsonObject) {
            deepMerge(baseValue, patchValue)
        } else {
            patchValue
        }
    }
    return JsonObject(merged)
}
