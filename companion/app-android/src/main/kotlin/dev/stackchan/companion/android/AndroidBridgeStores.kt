package dev.stackchan.companion.android

import android.content.Context
import dev.stackchan.companion.core.SettingsRepository
import dev.stackchan.companion.core.TrustedEndpointRegistry
import dev.stackchan.companion.core.companionJson
import java.util.UUID
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

data class SavedRobot(
    val robotId: String,
    val robotName: String,
    val firmwareVersion: String,
    val fingerprint: String,
    val lastBridgeUrl: String,
    val lastSeenMs: Long,
)

class AndroidBridgeStores(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun endpointId(): String {
        prefs.getString(KEY_ENDPOINT_ID, null)?.let { return it }
        val endpointId = "android-companion-${UUID.randomUUID()}"
        prefs.edit().putString(KEY_ENDPOINT_ID, endpointId).apply()
        return endpointId
    }

    fun loadSettings(): SettingsRepository =
        prefs.getString(KEY_SETTINGS, null)
            ?.let { text -> runCatching { SettingsRepository.decode(text) }.getOrNull() }
            ?: SettingsRepository()

    fun saveSettings(repository: SettingsRepository) {
        prefs.edit().putString(KEY_SETTINGS, repository.encode()).apply()
    }

    fun loadTrustedEndpoints(): TrustedEndpointRegistry =
        prefs.getString(KEY_TRUSTED_ENDPOINTS, null)
            ?.let { text -> runCatching { TrustedEndpointRegistry.decode(text) }.getOrNull() }
            ?: TrustedEndpointRegistry()

    fun saveTrustedEndpoints(registry: TrustedEndpointRegistry) {
        prefs.edit().putString(KEY_TRUSTED_ENDPOINTS, registry.encode()).apply()
    }

    fun loadSavedRobots(): List<SavedRobot> =
        prefs.getString(KEY_SAVED_ROBOTS, null)
            ?.let { text ->
                runCatching {
                    companionJson.parseToJsonElement(text)
                        .jsonObject["robots"]
                        ?.jsonArray
                        ?.mapNotNull { element -> element.jsonObject.toSavedRobotOrNull() }
                        .orEmpty()
                        .normalized()
                }.getOrNull()
            }
            ?: emptyList()

    fun rememberRobot(robot: SavedRobot): List<SavedRobot> {
        require(robot.robotId.isNotBlank()) { "robot_id is required" }
        val robots = (loadSavedRobots().filterNot { it.robotId == robot.robotId } + robot)
            .normalized()
        prefs.edit()
            .putString(KEY_SAVED_ROBOTS, encodeSavedRobots(robots))
            .apply()
        return robots
    }

    fun forgetRobot(robotId: String): List<SavedRobot> {
        val robots = loadSavedRobots().filterNot { it.robotId == robotId }.normalized()
        prefs.edit()
            .putString(KEY_SAVED_ROBOTS, encodeSavedRobots(robots))
            .apply()
        return robots
    }

    private companion object {
        const val PREFS_NAME = "stackchan_android_bridge"
        const val KEY_ENDPOINT_ID = "endpoint_id"
        const val KEY_SETTINGS = "settings_repository"
        const val KEY_TRUSTED_ENDPOINTS = "trusted_endpoints"
        const val KEY_SAVED_ROBOTS = "saved_robots"
    }
}

private fun List<SavedRobot>.normalized(): List<SavedRobot> =
    filter { it.robotId.isNotBlank() }
        .distinctBy { it.robotId }
        .sortedByDescending { it.lastSeenMs }
        .take(8)

private fun encodeSavedRobots(robots: List<SavedRobot>): String =
    buildJsonObject {
        put("robots", JsonArray(robots.map { it.toJsonObject() }))
    }.toString()

private fun SavedRobot.toJsonObject(): JsonObject =
    buildJsonObject {
        put("robot_id", robotId)
        put("robot_name", robotName)
        put("firmware_version", firmwareVersion)
        put("fingerprint", fingerprint)
        put("last_bridge_url", lastBridgeUrl)
        put("last_seen_ms", lastSeenMs)
    }

private fun JsonObject.toSavedRobotOrNull(): SavedRobot? {
    val robotId = this["robot_id"]?.jsonPrimitive?.content.orEmpty()
    if (robotId.isBlank()) {
        return null
    }
    return SavedRobot(
        robotId = robotId,
        robotName = this["robot_name"]?.jsonPrimitive?.content.orEmpty(),
        firmwareVersion = this["firmware_version"]?.jsonPrimitive?.content.orEmpty(),
        fingerprint = this["fingerprint"]?.jsonPrimitive?.content.orEmpty(),
        lastBridgeUrl = this["last_bridge_url"]?.jsonPrimitive?.content.orEmpty(),
        lastSeenMs = this["last_seen_ms"]?.jsonPrimitive?.longOrNull ?: 0,
    )
}
