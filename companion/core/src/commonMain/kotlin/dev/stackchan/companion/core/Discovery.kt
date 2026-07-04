package dev.stackchan.companion.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

const val STACKCHAN_BRIDGE_SERVICE = "_stackchan-bridge._tcp.local"
const val STACKCHAN_DEVICE_SERVICE = "_stackchan-device._tcp.local"
const val DEFAULT_BRIDGE_PORT = 8765

enum class DiscoveryMethod {
    MDNS,
    UDP_BEACON,
    MANUAL,
    BLE_BOOTSTRAP,
}

data class DiscoveredEndpoint(
    val endpointId: String,
    val endpointName: String,
    val endpointKind: String,
    val host: String,
    val port: Int,
    val protocol: String = CompanionIdentity.protocol,
    val capabilities: List<String> = emptyList(),
    val method: DiscoveryMethod,
)

@Serializable
data class UdpBridgeBeacon(
    val type: String = "stackchan_bridge_beacon",
    val protocol: String = CompanionIdentity.protocol,
    @SerialName("endpoint_id") val endpointId: String,
    @SerialName("endpoint_name") val endpointName: String,
    @SerialName("endpoint_kind") val endpointKind: String,
    val port: Int,
    val capabilities: List<String> = emptyList(),
)

fun UdpBridgeBeacon.toDiscoveredEndpoint(host: String): DiscoveredEndpoint =
    DiscoveredEndpoint(
        endpointId = endpointId,
        endpointName = endpointName,
        endpointKind = endpointKind,
        host = host,
        port = port,
        protocol = protocol,
        capabilities = capabilities,
        method = DiscoveryMethod.UDP_BEACON,
    )

fun endpointHelloToBeacon(endpointHello: EndpointHello, port: Int): UdpBridgeBeacon =
    UdpBridgeBeacon(
        endpointId = endpointHello.endpointId,
        endpointName = endpointHello.endpointName,
        endpointKind = endpointHello.endpointKind,
        port = port,
        capabilities = endpointHello.capabilities,
    )

fun encodeUdpBridgeBeacon(beacon: UdpBridgeBeacon): String =
    companionJson.encodeToString(UdpBridgeBeacon.serializer(), beacon)

fun decodeUdpBridgeBeacon(text: String): UdpBridgeBeacon {
    val beacon = companionJson.decodeFromString(UdpBridgeBeacon.serializer(), text)
    require(beacon.type == "stackchan_bridge_beacon") { "not a Stackchan bridge beacon: ${beacon.type}" }
    require(beacon.protocol == CompanionIdentity.protocol) { "unsupported protocol: ${beacon.protocol}" }
    require(beacon.endpointId.isNotBlank()) { "beacon endpoint_id is required" }
    require(beacon.endpointKind in setOf("pc", "android")) { "unsupported endpoint_kind: ${beacon.endpointKind}" }
    require(beacon.port in 1..65535) { "beacon port must be 1..65535" }
    return beacon
}

fun parseManualEndpoint(
    address: String,
    endpointId: String = "manual-endpoint",
    endpointName: String = "Manual endpoint",
    endpointKind: String = "pc",
): DiscoveredEndpoint {
    val trimmed = address.trim()
    require(trimmed.isNotEmpty()) { "manual endpoint address is required" }

    val withoutScheme = trimmed
        .removePrefix("ws://")
        .removePrefix("http://")
        .substringBefore("/")
    val host: String
    val port: Int

    if (withoutScheme.startsWith("[")) {
        val closing = withoutScheme.indexOf("]")
        require(closing > 1) { "invalid bracketed IPv6 address" }
        host = withoutScheme.substring(1, closing)
        val suffix = withoutScheme.substring(closing + 1)
        port = suffix.removePrefix(":").takeIf { it.isNotBlank() }?.toIntOrNull() ?: DEFAULT_BRIDGE_PORT
    } else {
        val colonCount = withoutScheme.count { it == ':' }
        if (colonCount == 1) {
            host = withoutScheme.substringBefore(":")
            port = withoutScheme.substringAfter(":").toIntOrNull() ?: error("invalid endpoint port")
        } else {
            host = withoutScheme
            port = DEFAULT_BRIDGE_PORT
        }
    }

    require(host.isNotBlank()) { "manual endpoint host is required" }
    require(port in 1..65535) { "manual endpoint port must be 1..65535" }
    require(endpointKind in setOf("pc", "android")) { "unsupported endpoint_kind: $endpointKind" }

    return DiscoveredEndpoint(
        endpointId = endpointId,
        endpointName = endpointName,
        endpointKind = endpointKind,
        host = host,
        port = port,
        capabilities = listOf("settings", "diagnostics"),
        method = DiscoveryMethod.MANUAL,
    )
}
