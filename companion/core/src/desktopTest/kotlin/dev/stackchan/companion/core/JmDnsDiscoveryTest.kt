package dev.stackchan.companion.core

import java.net.InetAddress
import java.net.ServerSocket
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class JmDnsDiscoveryTest {
    @Test
    fun jmdnsAdvertiseMapsBridgeEndpointMetadata() {
        val port = freeTcpPort()
        JmDnsDiscovery(InetAddress.getLoopbackAddress(), "stackchan-companion-test-discovery").use { discovery ->
            discovery.registerBridgeEndpoint(defaultDesktopEndpointHello("pc-studio-01"), port).use { registration ->
                val endpoint = registration.endpoint

                assertEquals("pc", endpoint.endpointKind)
                assertEquals(port, endpoint.port)
                assertEquals(DiscoveryMethod.MDNS, endpoint.method)
                assertTrue("settings" in endpoint.capabilities)
            }
        }
    }

    @Test
    fun jmdnsBrowseReturnsEmptyListWhenNoEndpointIsPresent() {
        JmDnsDiscovery(InetAddress.getLoopbackAddress(), "stackchan-companion-test-empty").use { browser ->
            assertTrue(browser.browseBridgeEndpoints(timeoutMs = 250).isEmpty())
        }
    }

    private fun freeTcpPort(): Int =
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
}
