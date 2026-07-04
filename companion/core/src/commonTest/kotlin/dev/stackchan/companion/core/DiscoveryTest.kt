package dev.stackchan.companion.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class DiscoveryTest {
    @Test
    fun manualEndpointDefaultsToBridgePort() {
        val endpoint = parseManualEndpoint("192.168.1.42")

        assertEquals("192.168.1.42", endpoint.host)
        assertEquals(DEFAULT_BRIDGE_PORT, endpoint.port)
        assertEquals(DiscoveryMethod.MANUAL, endpoint.method)
    }

    @Test
    fun manualEndpointAcceptsHostPortAndWebSocketUrl() {
        val endpoint = parseManualEndpoint("ws://stackchan.local:9001/bridge")

        assertEquals("stackchan.local", endpoint.host)
        assertEquals(9001, endpoint.port)
    }

    @Test
    fun manualEndpointAcceptsBracketedIpv6() {
        val endpoint = parseManualEndpoint("[fe80::1234]:9002")

        assertEquals("fe80::1234", endpoint.host)
        assertEquals(9002, endpoint.port)
    }

    @Test
    fun manualEndpointRejectsInvalidPort() {
        assertFailsWith<IllegalArgumentException> {
            parseManualEndpoint("192.168.1.42:70000")
        }
    }

    @Test
    fun endpointHelloCanBecomeUdpBeacon() {
        val beacon = endpointHelloToBeacon(defaultAndroidEndpointHello("phone-rob-01"), port = 8766)
        val encoded = encodeUdpBridgeBeacon(beacon)
        val decoded = decodeUdpBridgeBeacon(encoded)
        val endpoint = decoded.toDiscoveredEndpoint(host = "192.168.1.50")

        assertTrue("endpoint_id" in encoded)
        assertEquals("phone-rob-01", decoded.endpointId)
        assertEquals("android", endpoint.endpointKind)
        assertEquals("192.168.1.50", endpoint.host)
        assertEquals(DiscoveryMethod.UDP_BEACON, endpoint.method)
    }

    @Test
    fun udpBeaconRejectsWrongProtocol() {
        assertFailsWith<IllegalArgumentException> {
            decodeUdpBridgeBeacon(
                """
                {
                  "type": "stackchan_bridge_beacon",
                  "protocol": "stackchan.bridge.v2",
                  "endpoint_id": "phone-rob-01",
                  "endpoint_name": "Rob's Phone",
                  "endpoint_kind": "android",
                  "port": 8765,
                  "capabilities": ["settings"]
                }
                """.trimIndent(),
            )
        }
    }
}
