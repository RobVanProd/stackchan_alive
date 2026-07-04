package dev.stackchan.companion.core

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class UdpBeaconDiscoveryTest {
    @Test
    fun udpTransportReceivesValidBeaconOnLoopback() {
        val port = freeUdpPort()
        val discovery = UdpBeaconDiscovery(InetAddress.getLoopbackAddress())
        val future = CompletableFuture.supplyAsync {
            discovery.listenOnce(port, timeoutMs = 3000)
        }
        val beacon = endpointHelloToBeacon(defaultDesktopEndpointHello("pc-studio-01"), DEFAULT_BRIDGE_PORT)

        Thread.sleep(100)
        discovery.sendBeacon(beacon, targetHost = "127.0.0.1", targetPort = port)
        val endpoint = future.get(5, TimeUnit.SECONDS)

        requireNotNull(endpoint)
        assertEquals("pc-studio-01", endpoint.endpointId)
        assertEquals("pc", endpoint.endpointKind)
        assertEquals(DEFAULT_BRIDGE_PORT, endpoint.port)
        assertEquals(DiscoveryMethod.UDP_BEACON, endpoint.method)
    }

    @Test
    fun udpTransportIgnoresInvalidBeaconPayloads() {
        val port = freeUdpPort()
        val discovery = UdpBeaconDiscovery(InetAddress.getLoopbackAddress())
        val future = CompletableFuture.supplyAsync {
            discovery.listenOnce(port, timeoutMs = 3000)
        }

        Thread.sleep(100)
        sendRawUdp("""{"type":"stackchan_bridge_beacon","protocol":"stackchan.bridge.v2"}""", port)
        val endpoint = future.get(5, TimeUnit.SECONDS)

        assertNull(endpoint)
    }

    @Test
    fun udpTransportTimesOutWhenNoBeaconArrives() {
        val discovery = UdpBeaconDiscovery(InetAddress.getLoopbackAddress())

        assertNull(discovery.listenOnce(freeUdpPort(), timeoutMs = 100))
    }

    private fun sendRawUdp(text: String, port: Int) {
        val payload = text.encodeToByteArray()
        DatagramSocket().use { socket ->
            socket.send(
                DatagramPacket(
                    payload,
                    payload.size,
                    InetAddress.getLoopbackAddress(),
                    port,
                ),
            )
        }
    }

    private fun freeUdpPort(): Int =
        DatagramSocket(0).use { it.localPort }
}
