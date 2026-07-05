package dev.stackchan.companion.android

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import dev.stackchan.companion.core.SettingsRepository
import dev.stackchan.companion.core.TrustedEndpointRegistry
import dev.stackchan.companion.core.companionJson
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.util.Locale
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
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

data class AndroidModelAssetStatus(
    val localPath: String,
    val bytes: Long = 0,
    val downloaded: Boolean,
    val loaded: Boolean,
    val downloadId: Long?,
    val downloadInProgress: Boolean = downloadId != null,
)

data class AndroidPersonaLibraryStatus(
    val installedPersonas: List<String>,
    val importStatus: String,
    val exportStatus: String,
)

internal const val ANDROID_GEMMA_MODEL_FILE = "gemma-4-E2B-it.litertlm"
internal const val ANDROID_GEMMA_LITERTLM_BYTES = 2_588_147_712L
internal const val ANDROID_GEMMA_LITERTLM_SHA256 = "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
internal const val ANDROID_GEMMA_LITERTLM_URL =
    "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm"

class AndroidBridgeStores(context: Context) {
    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

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

    fun modelAssetStatus(): AndroidModelAssetStatus {
        val file = gemmaModelFile()
        val bytes = if (file.isFile) file.length() else 0L
        val downloaded = bytes == ANDROID_GEMMA_LITERTLM_BYTES
        val downloadId = activeGemmaDownloadId(downloaded)
        return AndroidModelAssetStatus(
            localPath = file.absolutePath,
            bytes = bytes,
            downloaded = downloaded,
            loaded = prefs.getBoolean(KEY_GEMMA_MODEL_LOADED, false) && downloaded,
            downloadId = downloadId,
            downloadInProgress = downloadId != null,
        )
    }

    fun startGemmaModelDownload(): AndroidModelAssetStatus {
        val file = gemmaModelFile()
        file.parentFile?.mkdirs()
        if (file.exists()) {
            file.delete()
        }
        val request = DownloadManager.Request(Uri.parse(ANDROID_GEMMA_LITERTLM_URL))
            .setTitle("Gemma-4-E2B LiteRT-LM")
            .setDescription("Downloading Stackchan Mobile Brain model")
            .setAllowedOverMetered(false)
            .setAllowedOverRoaming(false)
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setDestinationInExternalFilesDir(appContext, Environment.DIRECTORY_DOWNLOADS, "models/$ANDROID_GEMMA_MODEL_FILE")
        val manager = appContext.getSystemService(DownloadManager::class.java)
        val id = manager.enqueue(request)
        prefs.edit()
            .putLong(KEY_GEMMA_DOWNLOAD_ID, id)
            .putBoolean(KEY_GEMMA_MODEL_LOADED, false)
            .apply()
        return modelAssetStatus()
    }

    fun loadGemmaModel(): AndroidModelAssetStatus {
        val status = modelAssetStatus()
        require(status.downloaded) {
            "Gemma-4-E2B model is not ready; expected $ANDROID_GEMMA_LITERTLM_BYTES bytes from $ANDROID_GEMMA_LITERTLM_SHA256."
        }
        prefs.edit().putBoolean(KEY_GEMMA_MODEL_LOADED, true).apply()
        return modelAssetStatus()
    }

    fun ejectGemmaModel(): AndroidModelAssetStatus {
        prefs.edit().putBoolean(KEY_GEMMA_MODEL_LOADED, false).apply()
        return modelAssetStatus()
    }

    fun personaLibraryStatus(): AndroidPersonaLibraryStatus {
        val imported = importedPersonaIds()
        return AndroidPersonaLibraryStatus(
            installedPersonas = (BUNDLED_PERSONAS + imported).distinct().sorted(),
            importStatus = "Ready to import stackchan.persona-pack.v1 zip files.",
            exportStatus = "Ready to export active persona pack zip.",
        )
    }

    fun importPersonaZip(input: InputStream): AndroidPersonaLibraryStatus {
        val bytes = input.use { it.readBytes() }
        val personaId = validatePersonaZip(bytes)
        val destination = importedPersonaFile(personaId)
        destination.parentFile?.mkdirs()
        destination.writeBytes(bytes)
        return personaLibraryStatus().copy(importStatus = "Imported persona `$personaId`.")
    }

    fun exportPersonaZip(personaId: String, output: OutputStream): AndroidPersonaLibraryStatus {
        val normalized = personaId.sanitizedPersonaId()
        val imported = importedPersonaFile(normalized)
        if (imported.isFile) {
            imported.inputStream().use { input -> output.use { input.copyTo(it) } }
            return personaLibraryStatus().copy(exportStatus = "Exported imported persona `$normalized`.")
        }
        require(normalized in BUNDLED_PERSONAS) { "Persona `$personaId` is not installed." }
        output.use { stream ->
            ZipOutputStream(stream).use { zip ->
                val files = appContext.assets.list(normalized).orEmpty()
                require("pack.yaml" in files) { "Bundled persona `$normalized` is missing pack.yaml." }
                files.forEach { fileName ->
                    val entryName = "$normalized/$fileName"
                    zip.putNextEntry(ZipEntry(entryName))
                    appContext.assets.open("$normalized/$fileName").use { input -> input.copyTo(zip) }
                    zip.closeEntry()
                }
            }
        }
        return personaLibraryStatus().copy(exportStatus = "Exported bundled persona `$normalized`.")
    }

    private companion object {
        const val PREFS_NAME = "stackchan_android_bridge"
        const val KEY_ENDPOINT_ID = "endpoint_id"
        const val KEY_SETTINGS = "settings_repository"
        const val KEY_TRUSTED_ENDPOINTS = "trusted_endpoints"
        const val KEY_SAVED_ROBOTS = "saved_robots"
        const val KEY_GEMMA_DOWNLOAD_ID = "gemma4_e2b_download_id"
        const val KEY_GEMMA_MODEL_LOADED = "gemma4_e2b_model_loaded"
        val BUNDLED_PERSONAS = listOf("spark", "glow")
    }

    private fun gemmaModelFile() =
        java.io.File(appContext.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "models/$ANDROID_GEMMA_MODEL_FILE")

    private fun activeGemmaDownloadId(downloaded: Boolean): Long? {
        val storedId = prefs.getLong(KEY_GEMMA_DOWNLOAD_ID, -1L).takeIf { it > 0 } ?: return null
        if (downloaded) {
            return null
        }
        val manager = appContext.getSystemService(DownloadManager::class.java)
        manager.query(DownloadManager.Query().setFilterById(storedId)).use { cursor ->
            if (!cursor.moveToFirst()) {
                prefs.edit().remove(KEY_GEMMA_DOWNLOAD_ID).apply()
                return null
            }
            val status = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            if (status in setOf(
                    DownloadManager.STATUS_PENDING,
                    DownloadManager.STATUS_RUNNING,
                    DownloadManager.STATUS_PAUSED,
                )
            ) {
                return storedId
            }
        }
        prefs.edit().remove(KEY_GEMMA_DOWNLOAD_ID).apply()
        return null
    }

    private fun importedPersonaFile(personaId: String) =
        java.io.File(appContext.filesDir, "personas/imported/${personaId.sanitizedPersonaId()}.zip")

    private fun importedPersonaIds(): List<String> {
        val directory = java.io.File(appContext.filesDir, "personas/imported")
        return directory.listFiles { file -> file.isFile && file.extension.lowercase(Locale.US) == "zip" }
            ?.map { it.nameWithoutExtension.sanitizedPersonaId() }
            .orEmpty()
    }
}

private fun validatePersonaZip(bytes: ByteArray): String {
    val packYaml = ZipInputStream(bytes.inputStream()).use { zip ->
        generateSequence { zip.nextEntry }
            .firstOrNull { it.name.endsWith("pack.yaml") }
            ?.let {
                val out = ByteArrayOutputStream()
                zip.copyTo(out)
                out.toString(Charsets.UTF_8.name())
            }
    } ?: error("Persona zip must contain pack.yaml.")
    require(packYaml.contains("schema: stackchan.persona-pack.v1")) {
        "Persona pack schema must be stackchan.persona-pack.v1."
    }
    val id = packYaml.lineSequence()
        .firstOrNull { it.trimStart().startsWith("id:") }
        ?.substringAfter(":")
        ?.trim()
        ?.trim('"', '\'')
        .orEmpty()
        .sanitizedPersonaId()
    require(id.isNotBlank()) { "Persona pack id is required." }
    return id
}

private fun String.sanitizedPersonaId(): String =
    lowercase(Locale.US)
        .filter { it.isLetterOrDigit() || it == '-' || it == '_' }
        .take(32)

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
