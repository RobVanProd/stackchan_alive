package dev.stackchan.companion.desktop

import dev.stackchan.companion.core.CompanionEndpointServer
import dev.stackchan.companion.core.DEFAULT_BRIDGE_PORT
import dev.stackchan.companion.core.EndpointRequestRouter
import dev.stackchan.companion.core.EndpointServerConfig
import dev.stackchan.companion.core.SettingsRepositoryFileStore
import dev.stackchan.companion.core.TrustedEndpointFileStore
import dev.stackchan.companion.core.defaultDesktopEndpointHello
import java.nio.file.Files
import java.nio.file.Path

data class DesktopCompanionRuntimeConfig(
    val host: String = System.getProperty("stackchan.companion.host") ?: "0.0.0.0",
    val port: Int = System.getProperty("stackchan.companion.port")?.toIntOrNull() ?: DEFAULT_BRIDGE_PORT,
    val storageDir: Path = defaultCompanionStorageDir(),
    val endpointId: String = System.getProperty("stackchan.companion.endpoint_id") ?: "pc-companion-desktop",
)

class DesktopCompanionRuntime(
    private val config: DesktopCompanionRuntimeConfig = DesktopCompanionRuntimeConfig(),
) : AutoCloseable {
    private var server: CompanionEndpointServer? = null

    fun start(): DesktopCompanionRuntime {
        check(server == null) { "desktop companion runtime already started" }
        require(config.host.isNotBlank()) { "host is required" }
        require(config.port in 1..65535) { "port must be 1..65535" }
        Files.createDirectories(config.storageDir)

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

        server = CompanionEndpointServer(
            EndpointServerConfig(
                host = config.host,
                port = config.port,
                endpointHello = defaultDesktopEndpointHello(endpointId = config.endpointId),
                requestRouter = router,
            ),
        ).start()
        return this
    }

    override fun close() {
        server?.close()
        server = null
    }
}

private fun defaultCompanionStorageDir(): Path =
    Path.of(System.getProperty("user.home"), ".stackchan-alive", "companion")
