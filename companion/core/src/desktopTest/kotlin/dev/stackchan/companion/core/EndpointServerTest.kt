package dev.stackchan.companion.core

import java.net.ServerSocket
import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.time.Duration
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionStage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

class EndpointServerTest {
    @Test
    fun endpointServerAnswersDeviceHelloWithEndpointHello() = runBlocking {
        val port = freePort()
        CompanionEndpointServer(
            EndpointServerConfig(
                port = port,
                endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            ),
        ).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")

            client.send(
                encodeControlMessage(
                    DeviceHello(
                        deviceId = "stackchan-001",
                        deviceName = "Stackchan Alive Bench",
                        firmwareVersion = "dev-c2",
                        sampleRate = 16000,
                        capabilities = listOf("wake_gate", "pcm16_upload", "settings"),
                        trustedEndpointCount = 1,
                        activeBrainOwner = "pc-studio-01",
                    ),
                ),
            )

            val response = assertIs<EndpointHello>(decodeControlMessage(client.nextText()))
            val snapshot = server.currentSnapshot()

            assertEquals("phone-rob-01", response.endpointId)
            assertEquals("android", response.endpointKind)
            assertEquals("stackchan-001", snapshot.deviceId)
            assertEquals("dev-c2", snapshot.firmwareVersion)
            assertEquals("pc-studio-01", snapshot.activeBrainOwner)
            assertEquals("hello", snapshot.lastMessageType)
            assertEquals(1, snapshot.messagesReceived)
            client.close()
        }
    }

    @Test
    fun endpointServerReportsDecodeErrorsAsRecoverableBridgeErrors() {
        val port = freePort()
        CompanionEndpointServer(EndpointServerConfig(port = port)).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")

            client.send("""{"type":"endpoint_hello","protocol":"stackchan.bridge.v2"}""")

            val response = assertIs<BridgeError>(decodeControlMessage(client.nextText()))

            assertEquals("bad_control_message", response.code)
            assertTrue(response.recoverable)
            client.close()
        }
    }

    private fun freePort(): Int =
        ServerSocket(0).use { it.localPort }
}

private class TestWebSocketClient private constructor(
    private val socket: WebSocket,
    private val messages: CompletableFuture<String>,
) {
    fun send(text: String) {
        socket.sendText(text, true).join()
    }

    fun nextText(): String =
        messages.get(Duration.ofSeconds(5).toMillis(), java.util.concurrent.TimeUnit.MILLISECONDS)

    fun close() {
        socket.sendClose(WebSocket.NORMAL_CLOSURE, "done").join()
    }

    companion object {
        fun connect(uri: String): TestWebSocketClient {
            val messages = CompletableFuture<String>()
            val listener = object : WebSocket.Listener {
                override fun onText(
                    webSocket: WebSocket,
                    data: CharSequence,
                    last: Boolean,
                ): CompletionStage<*> {
                    if (last) {
                        messages.complete(data.toString())
                    }
                    webSocket.request(1)
                    return CompletableFuture.completedFuture(null)
                }
            }
            val socket = HttpClient
                .newHttpClient()
                .newWebSocketBuilder()
                .connectTimeout(Duration.ofSeconds(5))
                .buildAsync(URI.create(uri), listener)
                .get(Duration.ofSeconds(5).toMillis(), java.util.concurrent.TimeUnit.MILLISECONDS)
            socket.request(1)
            return TestWebSocketClient(socket, messages)
        }
    }
}
