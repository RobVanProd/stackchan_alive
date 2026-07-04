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
            mdnsError = mdnsError,
        )

    suspend fun sessionSnapshot(): EndpointSessionSnapshot =
        server?.currentSnapshot() ?: EndpointSessionSnapshot()

    fun diagnosticsSnapshot(domains: List<String> = emptyList()): DiagnosticsSnapshot =
        requestRouter?.handle(DiagnosticsRequest(domains = domains)) as? DiagnosticsSnapshot
            ?: DiagnosticsSnapshot(bridge = JsonObject(emptyMap()))

    fun startBrainService(): DesktopBrainSupervisorSnapshot =
        brainSupervisor.start().snapshot()

    fun stopBrainService(): DesktopBrainSupervisorSnapshot =
        brainSupervisor.stop().snapshot()

    fun restartBrainService(): DesktopBrainSupervisorSnapshot =
        brainSupervisor.restart().snapshot()

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
