package dev.stackchan.companion.core

import java.net.InetAddress
import javax.jmdns.JmDNS
import javax.jmdns.ServiceInfo

class JmDnsDiscovery(
    private val address: InetAddress = InetAddress.getLoopbackAddress(),
    private val instanceName: String = "stackchan-companion",
) : AutoCloseable {
    private val jmdns: JmDNS = JmDNS.create(address, instanceName)

    fun registerBridgeEndpoint(endpointHello: EndpointHello, port: Int): RegisteredService {
        require(port in 1..65535) { "port must be 1..65535" }
        val serviceInfo = ServiceInfo.create(
            "$STACKCHAN_BRIDGE_SERVICE.",
            endpointHello.endpointName,
            port,
            0,
            0,
            mapOf(
                "endpoint_id" to endpointHello.endpointId,
                "endpoint_kind" to endpointHello.endpointKind,
                "proto" to endpointHello.protocol,
                "capabilities" to endpointHello.capabilities.joinToString(","),
            ),
        )
        jmdns.registerService(serviceInfo)
        return RegisteredService(
            jmdns = jmdns,
            serviceInfo = serviceInfo,
            endpoint = serviceInfo.toDiscoveredEndpoint(address.hostAddress)
                ?: error("registered bridge endpoint metadata is invalid"),
        )
    }

    fun browseBridgeEndpoints(timeoutMs: Long = 1000): List<DiscoveredEndpoint> =
        browse(STACKCHAN_BRIDGE_SERVICE, timeoutMs)

    fun browseDeviceEndpoints(timeoutMs: Long = 1000): List<DiscoveredEndpoint> =
        browse(STACKCHAN_DEVICE_SERVICE, timeoutMs)

    override fun close() {
        runCatching { jmdns.unregisterAllServices() }
        runCatching { jmdns.close() }
    }

    private fun browse(serviceType: String, timeoutMs: Long): List<DiscoveredEndpoint> {
        require(timeoutMs > 0) { "timeoutMs must be positive" }
        return jmdns
            .list("$serviceType.", timeoutMs)
            .mapNotNull { it.toDiscoveredEndpoint() }
            .distinctBy { "${it.endpointId}:${it.host}:${it.port}" }
    }
}

class RegisteredService(
    private val jmdns: JmDNS,
    private val serviceInfo: ServiceInfo,
    val endpoint: DiscoveredEndpoint,
) : AutoCloseable {
    override fun close() {
        runCatching { jmdns.unregisterService(serviceInfo) }
    }
}

private fun ServiceInfo.toDiscoveredEndpoint(fallbackHost: String? = null): DiscoveredEndpoint? {
    val endpointId = getPropertyString("endpoint_id")?.takeIf { it.isNotBlank() } ?: return null
    val endpointKind = getPropertyString("endpoint_kind")?.takeIf { it.isNotBlank() } ?: "pc"
    val protocol = getPropertyString("proto") ?: CompanionIdentity.protocol
    if (protocol != CompanionIdentity.protocol) {
        return null
    }
    val host = inet4Addresses.firstOrNull()?.hostAddress
        ?: inet6Addresses.firstOrNull()?.hostAddress
        ?: fallbackHost
        ?: return null
    val capabilities = getPropertyString("capabilities")
        ?.split(",")
        ?.map { it.trim() }
        ?.filter { it.isNotEmpty() }
        .orEmpty()
    return DiscoveredEndpoint(
        endpointId = endpointId,
        endpointName = name,
        endpointKind = endpointKind,
        host = host,
        port = port,
        protocol = protocol,
        capabilities = capabilities,
        method = DiscoveryMethod.MDNS,
    )
}
