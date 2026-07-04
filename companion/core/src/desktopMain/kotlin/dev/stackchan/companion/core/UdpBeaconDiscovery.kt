package dev.stackchan.companion.core

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketTimeoutException

private const val MAX_BEACON_BYTES = 2048

class UdpBeaconDiscovery(
    private val listenAddress: InetAddress = InetAddress.getByName("0.0.0.0"),
) {
    fun sendBeacon(
        beacon: UdpBridgeBeacon,
        targetHost: String,
        targetPort: Int,
    ) {
        require(targetPort in 1..65535) { "target port must be 1..65535" }
        val payload = encodeUdpBridgeBeacon(beacon).encodeToByteArray()
        require(payload.size <= MAX_BEACON_BYTES) { "beacon payload is too large: ${payload.size}" }
        DatagramSocket().use { socket ->
            socket.broadcast = true
            val packet = DatagramPacket(
                payload,
                payload.size,
                InetAddress.getByName(targetHost),
                targetPort,
            )
            socket.send(packet)
        }
    }

    fun listenOnce(port: Int, timeoutMs: Int = 1000): DiscoveredEndpoint? {
        require(port in 1..65535) { "listen port must be 1..65535" }
        require(timeoutMs > 0) { "timeoutMs must be positive" }
        DatagramSocket(InetSocketAddress(listenAddress, port)).use { socket ->
            socket.soTimeout = timeoutMs
            val buffer = ByteArray(MAX_BEACON_BYTES)
            val packet = DatagramPacket(buffer, buffer.size)
            return try {
                socket.receive(packet)
                val text = packet.data.decodeToString(0, packet.length)
                decodeUdpBridgeBeacon(text).toDiscoveredEndpoint(packet.address.hostAddress)
            } catch (_: SocketTimeoutException) {
                null
            } catch (_: IllegalArgumentException) {
                null
            }
        }
    }
}
