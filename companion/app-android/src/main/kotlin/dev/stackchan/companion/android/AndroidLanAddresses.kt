package dev.stackchan.companion.android

import dev.stackchan.companion.core.DEFAULT_BRIDGE_PORT
import dev.stackchan.companion.core.EndpointHello
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.security.MessageDigest
import java.util.Collections
import java.util.Enumeration

fun localBridgeManualUrls(port: Int = DEFAULT_BRIDGE_PORT): List<String> {
    require(port in 1..65535) { "bridge port must be 1..65535" }
    val addresses = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { networkInterface ->
                runCatching {
                    networkInterface.isUp && !networkInterface.isLoopback && !networkInterface.isVirtual
                }.getOrDefault(false)
            }
            .flatMap { networkInterface -> networkInterface.inetAddresses.toList() }
            .filter { it.isUsableLanAddress() }
            .sortedWith(
                compareBy<InetAddress> { it !is Inet4Address }
                    .thenBy { !it.isSiteLocalAddress }
                    .thenBy { it.hostAddress },
            )
            .map { "ws://${it.toUrlHost()}:$port/bridge" }
            .distinct()
    }.getOrDefault(emptyList())
    return addresses.ifEmpty { listOf("ws://<phone-lan-ip>:$port/bridge") }
}

fun primaryBridgeManualUrl(port: Int = DEFAULT_BRIDGE_PORT): String =
    localBridgeManualUrls(port).first()

fun androidPairingShortCode(endpointHello: EndpointHello, primaryBridgeUrl: String): String =
    sha256Hex("${endpointHello.endpointId}|${endpointHello.appVersion}|$primaryBridgeUrl|pair")
        .take(6)
        .uppercase()

fun androidPairingFingerprint(endpointHello: EndpointHello, primaryBridgeUrl: String): String =
    "sha256:${sha256Hex("${endpointHello.endpointId}|${endpointHello.appVersion}|$primaryBridgeUrl").take(32)}"

private fun InetAddress.isUsableLanAddress(): Boolean =
    !isAnyLocalAddress &&
        !isLoopbackAddress &&
        !isLinkLocalAddress &&
        !isMulticastAddress &&
        (this is Inet4Address || this is Inet6Address)

private fun InetAddress.toUrlHost(): String {
    val host = hostAddress?.substringBefore('%').orEmpty()
    return if (this is Inet6Address) "[$host]" else host
}

private fun <T> Enumeration<T>?.toList(): List<T> =
    this?.let { Collections.list(it) }.orEmpty()

private fun sha256Hex(value: String): String =
    MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
