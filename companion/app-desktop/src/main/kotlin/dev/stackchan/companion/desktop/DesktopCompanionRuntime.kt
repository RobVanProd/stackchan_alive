package dev.stackchan.companion.desktop

import dev.stackchan.companion.core.CompanionEndpointServer
import dev.stackchan.companion.core.DEFAULT_BRIDGE_PORT
import dev.stackchan.companion.core.DiagnosticsRequest
import dev.stackchan.companion.core.DiagnosticsSnapshot
import dev.stackchan.companion.core.DiscoveredEndpoint
import dev.stackchan.companion.core.EndpointRequestRouter
import dev.stackchan.companion.core.EndpointSessionSnapshot
import dev.stackchan.companion.core.EndpointServerConfig
import dev.stackchan.companion.core.JmDnsDiscovery
import dev.stackchan.companion.core.RegisteredService
import dev.stackchan.companion.core.SettingsRepositoryFileStore
import dev.stackchan.companion.core.TextTurnSubmitResult
import dev.stackchan.companion.core.TrustedEndpointFileStore
import dev.stackchan.companion.core.defaultDesktopEndpointHello
import java.net.InetAddress
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.serialization.json.JsonObject

data class DesktopCompanionRuntimeConfig(
    val host: String = System.getProperty("stackchan.companion.host") ?: "0.0.0.0",
    val port: Int = System.getProperty("stackchan.companion.port")?.toIntOrNull() ?: DEFAULT_BRIDGE_PORT,
    val storageDir: Path = defaultCompanionStorageDir(),
    val endpointId: String = System.getProperty("stackchan.companion.endpoint_id") ?: "pc-companion-desktop",
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

    fun start(): DesktopCompanionRuntime {
        check(server == null) { "desktop companion runtime already started" }
        require(config.host.isNotBlank()) { "host is required" }
        require(config.port in 1..65535) { "port must be 1..65535" }
        Files.createDirectories(config.storageDir)
        val endpointHello = defaultDesktopEndpointHello(endpointId = config.endpointId)

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

    fun diagnosticsSnapshot(domains: List<String> = emptyList()): DiagnosticsSnapshot =
        requestRouter?.handle(DiagnosticsRequest(domains = domains)) as? DiagnosticsSnapshot
            ?: DiagnosticsSnapshot(bridge = JsonObject(emptyMap()))

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
