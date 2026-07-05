package dev.stackchan.companion.desktop

import dev.stackchan.companion.core.ClaimBrain
import dev.stackchan.companion.core.CompanionEndpointServer
import dev.stackchan.companion.core.DEFAULT_BRIDGE_PORT
import dev.stackchan.companion.core.DiagnosticsRequest
import dev.stackchan.companion.core.DiagnosticsSnapshot
import dev.stackchan.companion.core.DiscoveredEndpoint
import dev.stackchan.companion.core.EndpointRequestRouter
import dev.stackchan.companion.core.EndpointSessionSnapshot
import dev.stackchan.companion.core.EndpointServerConfig
import dev.stackchan.companion.core.JmDnsDiscovery
import dev.stackchan.companion.core.ProtectedControlSubmitResult
import dev.stackchan.companion.core.RegisteredService
import dev.stackchan.companion.core.ReleaseBrain
import dev.stackchan.companion.core.SettingsRepositoryFileStore
import dev.stackchan.companion.core.SettingsGet
import dev.stackchan.companion.core.SettingsSet
import dev.stackchan.companion.core.SettingsSnapshot
import dev.stackchan.companion.core.TextTurnSubmitResult
import dev.stackchan.companion.core.TrustedEndpointFileStore
import dev.stackchan.companion.core.defaultDesktopEndpointHello
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

data class DesktopCompanionRuntimeConfig(
    val host: String = System.getProperty("stackchan.companion.host") ?: "0.0.0.0",
    val port: Int = System.getProperty("stackchan.companion.port")?.toIntOrNull() ?: DEFAULT_BRIDGE_PORT,
    val storageDir: Path = defaultCompanionStorageDir(),
    val endpointId: String = System.getProperty("stackchan.companion.endpoint_id") ?: "pc-companion-desktop",
    val pairingCode: String? = System.getProperty("stackchan.companion.pairing_code")?.takeIf { it.isNotBlank() },
    val advertiseMdns: Boolean = System.getProperty("stackchan.companion.mdns")?.toBooleanStrictOrNull() ?: true,
    val mdnsAddress: InetAddress? = null,
    val mdnsInstanceName: String = System.getProperty("stackchan.companion.mdns.instance") ?: "stackchan-companion-desktop",
    val brainSupervisorConfig: DesktopBrainSupervisorConfig = DesktopBrainSupervisorConfig(),
)

data class DesktopCompanionRuntimeSnapshot(
    val host: String,
    val port: Int,
    val storageDir: Path,
    val endpointId: String,
    val mdnsAdvertised: Boolean,
    val mdnsEndpoint: DiscoveredEndpoint?,
    val brainSupervisor: DesktopBrainSupervisorSnapshot,
    val diagnosticsExportPath: Path?,
    val diagnosticsExportError: String = "",
    val c6RehearsalPath: Path? = null,
    val c6RehearsalError: String = "",
    val c6RehearsalRunning: Boolean = false,
    val mdnsError: String = "",
)

data class DesktopModelAssetStatus(
    val localPath: String,
    val bytes: Long = 0,
    val downloaded: Boolean,
    val loaded: Boolean,
    val downloadInProgress: Boolean = false,
    val checksumVerified: Boolean = false,
)

data class DesktopPersonaLibraryStatus(
    val installedPersonas: List<String>,
    val importStatus: String,
    val exportStatus: String,
)

class DesktopCompanionRuntime(
    private val config: DesktopCompanionRuntimeConfig = DesktopCompanionRuntimeConfig(),
) : AutoCloseable {
    private var server: CompanionEndpointServer? = null
    private var discovery: JmDnsDiscovery? = null
    private var registration: RegisteredService? = null
    private var requestRouter: EndpointRequestRouter? = null
    private val brainSupervisor = DesktopBrainSupervisor(config.brainSupervisorConfig)
    private var mdnsError: String = ""
    private var diagnosticsExportPath: Path? = null
    private var diagnosticsExportError: String = ""
    private var c6RehearsalPath: Path? = null
    private var c6RehearsalError: String = ""
    private var c6RehearsalRunning: Boolean = false
    @Volatile
    private var modelDownloadInProgress: Boolean = false

    fun start(): DesktopCompanionRuntime {
        check(server == null) { "desktop companion runtime already started" }
        require(config.host.isNotBlank()) { "host is required" }
        require(config.port in 1..65535) { "port must be 1..65535" }
        Files.createDirectories(config.storageDir)
        val endpointHello = defaultDesktopEndpointHello(
            endpointId = config.endpointId,
            pairingCode = config.pairingCode,
        )

        val settingsStore = SettingsRepositoryFileStore(config.storageDir.resolve("settings.json"))
        val trustStore = TrustedEndpointFileStore(config.storageDir.resolve("trusted_endpoints.json"))
        val settingsRepository = settingsStore.load()
        val trustedEndpointRegistry = trustStore.load()
        val router = EndpointRequestRouter(
            settingsRepository = settingsRepository,
            trustedEndpointRegistry = trustedEndpointRegistry,
            onSettingsChanged = settingsStore::save,
            onTrustedEndpointsChanged = trustStore::save,
        )
        requestRouter = router

        server = CompanionEndpointServer(
            EndpointServerConfig(
                host = config.host,
                port = config.port,
                endpointHello = endpointHello,
                requestRouter = router,
            ),
        ).start()
        if (config.advertiseMdns) {
            runCatching {
                discovery = JmDnsDiscovery(
                    address = config.mdnsAddress ?: defaultMdnsAddress(config.host),
                    instanceName = config.mdnsInstanceName,
                )
                registration = discovery?.registerBridgeEndpoint(endpointHello, config.port)
            }.onFailure { error ->
                mdnsError = error.message ?: error::class.simpleName.orEmpty()
                registration = null
                discovery?.close()
                discovery = null
            }
        }
        return this
    }

    fun snapshot(): DesktopCompanionRuntimeSnapshot =
        DesktopCompanionRuntimeSnapshot(
            host = config.host,
            port = config.port,
            storageDir = config.storageDir,
            endpointId = config.endpointId,
            mdnsAdvertised = registration != null,
            mdnsEndpoint = registration?.endpoint,
            brainSupervisor = brainSupervisor.snapshot(),
            diagnosticsExportPath = diagnosticsExportPath,
            diagnosticsExportError = diagnosticsExportError,
            c6RehearsalPath = c6RehearsalPath,
            c6RehearsalError = c6RehearsalError,
            c6RehearsalRunning = c6RehearsalRunning,
            mdnsError = mdnsError,
        )

    suspend fun sessionSnapshot(): EndpointSessionSnapshot =
        server?.currentSnapshot() ?: EndpointSessionSnapshot()

    suspend fun submitTextTurn(text: String): TextTurnSubmitResult {
        val bridge = server
            ?: return TextTurnSubmitResult(
                accepted = false,
                detail = "Desktop bridge runtime is not running.",
            )
        return bridge.submitTextTurn(text)
    }

    suspend fun claimBrain(): ProtectedControlSubmitResult {
        val bridge = server
            ?: return ProtectedControlSubmitResult(
                accepted = false,
                messageType = "claim_brain",
                detail = "Desktop bridge runtime is not running.",
            )
        return bridge.submitProtectedControl(
            ClaimBrain(endpointId = config.endpointId, reason = "operator selected desktop brain"),
        )
    }

    suspend fun releaseBrain(): ProtectedControlSubmitResult {
        val bridge = server
            ?: return ProtectedControlSubmitResult(
                accepted = false,
                messageType = "release_brain",
                detail = "Desktop bridge runtime is not running.",
            )
        return bridge.submitProtectedControl(
            ReleaseBrain(endpointId = config.endpointId, reason = "operator released desktop brain"),
        )
    }

    fun diagnosticsSnapshot(domains: List<String> = emptyList()): DiagnosticsSnapshot =
        requestRouter?.handle(DiagnosticsRequest(domains = domains)) as? DiagnosticsSnapshot
            ?: DiagnosticsSnapshot(bridge = JsonObject(emptyMap()))

    fun settingsSnapshot(domains: List<String> = emptyList()): SettingsSnapshot =
        requestRouter?.handle(SettingsGet(domains = domains)) as? SettingsSnapshot
            ?: SettingsSnapshot(version = 1, settings = JsonObject(emptyMap()))

    fun selectNextPersona(): SettingsSnapshot {
        val snapshot = settingsSnapshot()
        val installed = personaLibraryStatus().installedPersonas.ifEmpty { BUNDLED_PERSONAS }
        val active = snapshot.settings.stringValue("persona", "active", "spark")
        val next = installed.nextAfter(active)
        return applySettingsPatch(
            buildJsonObject {
                put("persona", buildJsonObject {
                    put("active", JsonPrimitive(next))
                })
            },
        )
    }

    fun toggleDisplayReducedMotion(): SettingsSnapshot {
        val snapshot = settingsSnapshot()
        val next = !snapshot.settings.booleanValue("display", "reduced_motion")
        return applySettingsPatch(
            buildJsonObject {
                put("display", buildJsonObject {
                    put("reduced_motion", JsonPrimitive(next))
                })
            },
        )
    }

    fun toggleDiagnosticsLogExport(): SettingsSnapshot {
        val snapshot = settingsSnapshot()
        val next = !snapshot.settings.booleanValue("privacy", "export_logs")
        return applySettingsPatch(
            buildJsonObject {
                put("privacy", buildJsonObject {
                    put("export_logs", JsonPrimitive(next))
                })
            },
        )
    }

    private fun applySettingsPatch(patch: JsonObject): SettingsSnapshot {
        val router = requestRouter ?: error("Desktop bridge runtime is not running.")
        val snapshot = settingsSnapshot()
        val result = router.handle(SettingsSet(version = snapshot.version, settings = patch))
        check((result as? dev.stackchan.companion.core.SettingsResult)?.ok == true) { "Settings update was rejected." }
        return settingsSnapshot()
    }

    fun modelAssetStatus(): DesktopModelAssetStatus {
        val file = gemmaModelFile()
        val bytes = if (Files.isRegularFile(file)) Files.size(file) else 0L
        val downloaded = bytes == GEMMA_LITERTLM_BYTES
        val checksumVerified = downloaded && Files.isRegularFile(gemmaLoadedMarker()) &&
            gemmaModelChecksum(file) == GEMMA_LITERTLM_SHA256
        return DesktopModelAssetStatus(
            localPath = file.toString(),
            bytes = bytes,
            downloaded = downloaded,
            loaded = checksumVerified,
            checksumVerified = checksumVerified,
            downloadInProgress = modelDownloadInProgress,
        )
    }

    fun downloadGemmaModel(): DesktopModelAssetStatus {
        check(!modelDownloadInProgress) { "Gemma-4-E2B download is already running." }
        modelDownloadInProgress = true
        val file = gemmaModelFile()
        return try {
            Files.createDirectories(file.parent)
            val temp = file.resolveSibling("${file.fileName}.tmp")
            val request = HttpRequest.newBuilder(URI.create(GEMMA_LITERTLM_URL))
                .GET()
                .build()
            val response = HttpClient.newBuilder()
                .followRedirects(HttpClient.Redirect.ALWAYS)
                .build()
                .send(request, HttpResponse.BodyHandlers.ofFile(temp))
            check(response.statusCode() in 200..299) {
                "Gemma-4-E2B download failed with HTTP ${response.statusCode()}"
            }
            Files.move(temp, file, StandardCopyOption.REPLACE_EXISTING)
            Files.deleteIfExists(gemmaLoadedMarker())
            modelAssetStatus()
        } finally {
            modelDownloadInProgress = false
        }
    }

    fun loadGemmaModel(): DesktopModelAssetStatus {
        val status = modelAssetStatus()
        require(status.downloaded) {
            "Gemma-4-E2B model is not ready; expected $GEMMA_LITERTLM_BYTES bytes from $GEMMA_LITERTLM_SHA256."
        }
        require(gemmaModelChecksum(gemmaModelFile()) == GEMMA_LITERTLM_SHA256) {
            "Gemma-4-E2B checksum mismatch; expected $GEMMA_LITERTLM_SHA256. Delete the model and download it again."
        }
        Files.createDirectories(gemmaLoadedMarker().parent)
        Files.writeString(gemmaLoadedMarker(), "loaded\n")
        return modelAssetStatus()
    }

    fun ejectGemmaModel(): DesktopModelAssetStatus {
        Files.deleteIfExists(gemmaLoadedMarker())
        return modelAssetStatus()
    }

    fun personaLibraryStatus(): DesktopPersonaLibraryStatus {
        val imported = importedPersonaIds()
        return DesktopPersonaLibraryStatus(
            installedPersonas = (BUNDLED_PERSONAS + imported).distinct().sorted(),
            importStatus = "Ready to import stackchan.persona-pack.v1 zip files.",
            exportStatus = "Ready to export active persona pack zip.",
        )
    }

    fun importPersonaZip(input: Path): DesktopPersonaLibraryStatus {
        val bytes = Files.readAllBytes(input)
        val personaId = validatePersonaZip(bytes)
        val destination = importedPersonaFile(personaId)
        Files.createDirectories(destination.parent)
        Files.write(destination, bytes)
        return personaLibraryStatus().copy(importStatus = "Imported persona `$personaId`.")
    }

    fun exportPersonaZip(personaId: String, output: Path): DesktopPersonaLibraryStatus {
        val normalized = personaId.sanitizedPersonaId()
        val imported = importedPersonaFile(normalized)
        output.toAbsolutePath().parent?.let { Files.createDirectories(it) }
        if (Files.isRegularFile(imported)) {
            Files.copy(imported, output, StandardCopyOption.REPLACE_EXISTING)
            return personaLibraryStatus().copy(exportStatus = "Exported imported persona `$normalized`.")
        }
        require(normalized in BUNDLED_PERSONAS) { "Persona `$personaId` is not installed." }
        val personaDir = defaultRepoRoot().resolve("personas").resolve(normalized)
        require(Files.isRegularFile(personaDir.resolve("pack.yaml"))) {
            "Bundled persona `$normalized` is missing pack.yaml."
        }
        ZipOutputStream(Files.newOutputStream(output)).use { zip ->
            Files.walk(personaDir).use { paths ->
                paths
                    .filter { Files.isRegularFile(it) }
                    .forEach { file ->
                        val entryName = "$normalized/${personaDir.relativize(file).toString().replace('\\', '/')}"
                        zip.putNextEntry(ZipEntry(entryName))
                        Files.copy(file, zip)
                        zip.closeEntry()
                    }
            }
        }
        return personaLibraryStatus().copy(exportStatus = "Exported bundled persona `$normalized`.")
    }

    fun startBrainService(): DesktopBrainSupervisorSnapshot =
        brainSupervisor.start().snapshot()

    fun stopBrainService(): DesktopBrainSupervisorSnapshot =
        brainSupervisor.stop().snapshot()

    fun restartBrainService(): DesktopBrainSupervisorSnapshot =
        brainSupervisor.restart().snapshot()

    suspend fun exportDiagnosticsEvidenceFile(
        outputDir: Path = config.storageDir.resolve("diagnostics"),
    ): Path {
        return try {
            Files.createDirectories(outputDir)
            val path = outputDir.resolve("DIAGNOSTICS_EXPORT.json")
            Files.writeString(path, exportDiagnosticsEvidenceJson())
            diagnosticsExportPath = path
            diagnosticsExportError = ""
            path
        } catch (error: Exception) {
            diagnosticsExportError = error.message ?: error.javaClass.simpleName
            throw error
        }
    }

    suspend fun runC6GuiRehearsal(
        outputDir: Path = config.storageDir.resolve("diagnostics").resolve("c6-gui-rehearsal"),
    ): BrainSupervisorRehearsalResult {
        check(!c6RehearsalRunning) { "C6 GUI rehearsal is already running" }
        c6RehearsalRunning = true
        c6RehearsalError = ""
        return try {
            val result = runBrainSupervisorGuiRehearsal(outputDir)
            c6RehearsalPath = result.evidencePath
            c6RehearsalError = if (result.report.ok) "" else "C6 GUI rehearsal failed"
            result
        } catch (error: Exception) {
            c6RehearsalError = error.message ?: error.javaClass.simpleName
            throw error
        } finally {
            c6RehearsalRunning = false
        }
    }

    private fun gemmaModelFile(): Path =
        config.storageDir.resolve("models").resolve(GEMMA_MODEL_FILE)

    private fun gemmaLoadedMarker(): Path =
        config.storageDir.resolve("models").resolve(".gemma-4-e2b.loaded")

    private fun importedPersonaFile(personaId: String): Path =
        config.storageDir.resolve("personas").resolve("imported").resolve("${personaId.sanitizedPersonaId()}.zip")

    private fun importedPersonaIds(): List<String> {
        val directory = config.storageDir.resolve("personas").resolve("imported")
        if (!Files.isDirectory(directory)) {
            return emptyList()
        }
        return Files.list(directory).use { paths ->
            paths
                .filter { Files.isRegularFile(it) && it.fileName.toString().lowercase(Locale.US).endsWith(".zip") }
                .map { it.fileName.toString().removeSuffix(".zip").sanitizedPersonaId() }
                .toList()
        }
    }

    override fun close() {
        brainSupervisor.close()
        registration?.close()
        registration = null
        discovery?.close()
        discovery = null
        server?.close()
        server = null
        requestRouter = null
        mdnsError = ""
        diagnosticsExportPath = null
        diagnosticsExportError = ""
        c6RehearsalPath = null
        c6RehearsalError = ""
        c6RehearsalRunning = false
    }
}

private fun defaultCompanionStorageDir(): Path =
    Path.of(System.getProperty("user.home"), ".stackchan-alive", "companion")

private fun defaultMdnsAddress(host: String): InetAddress =
    System.getProperty("stackchan.companion.mdns.address")
        ?.takeIf { it.isNotBlank() }
        ?.let { InetAddress.getByName(it) }
        ?: if (host == "127.0.0.1" || host == "localhost") {
            InetAddress.getLoopbackAddress()
        } else {
            InetAddress.getLocalHost()
        }

private const val GEMMA_MODEL_FILE = "gemma-4-E2B-it.litertlm"
private const val GEMMA_LITERTLM_BYTES = 2_588_147_712L
private const val GEMMA_LITERTLM_SHA256 = "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
private const val GEMMA_LITERTLM_URL =
    "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm"
private val BUNDLED_PERSONAS = listOf("spark", "glow")

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

internal fun gemmaModelChecksum(path: Path): String {
    val digest = MessageDigest.getInstance("SHA-256")
    Files.newInputStream(path).use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) {
                break
            }
            digest.update(buffer, 0, read)
        }
    }
    return digest.digest().joinToString(separator = "") { byte -> "%02x".format(byte) }
}

private fun JsonObject.stringValue(domain: String, key: String, fallback: String): String =
    this[domain]
        ?.let { runCatching { it.jsonObject }.getOrNull() }
        ?.get(key)
        ?.jsonPrimitive
        ?.contentOrNull
        ?.takeIf { it.isNotBlank() }
        ?: fallback

private fun JsonObject.booleanValue(domain: String, key: String): Boolean =
    stringValue(domain, key, "false").toBooleanStrictOrNull() ?: false

private fun List<String>.nextAfter(current: String): String {
    val normalized = distinct().sorted()
    if (normalized.isEmpty()) {
        return current
    }
    val index = normalized.indexOf(current)
    return normalized[(if (index < 0) 0 else index + 1) % normalized.size]
}
