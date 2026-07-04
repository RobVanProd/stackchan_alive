package dev.stackchan.companion.core

import java.net.ServerSocket
import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.time.Duration
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionStage
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
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

    @Test
    fun endpointServerRoutesSettingsRequests() {
        val port = freePort()
        CompanionEndpointServer(EndpointServerConfig(port = port)).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")

            client.send(
                encodeControlMessage(
                    SettingsSet(
                        version = 1,
                        settings = buildJsonObject {
                            put("display", buildJsonObject {
                                put("brightness", JsonPrimitive(58))
                            })
                        },
                    ),
                ),
            )
            val setResponse = assertIs<SettingsResult>(decodeControlMessage(client.nextText()))

            client.send(encodeControlMessage(SettingsGet(domains = listOf("display"))))
            val snapshot = assertIs<SettingsSnapshot>(decodeControlMessage(client.nextText()))

            assertTrue(setResponse.ok)
            assertEquals(2, setResponse.version)
            assertEquals(
                58,
                snapshot.settings["display"]!!.jsonObject["brightness"]!!.jsonPrimitive.content.toInt(),
            )
            client.close()
        }
    }

    private fun freePort(): Int =
        ServerSocket(0).use { it.localPort }
}

private class TestWebSocketClient private constructor(
    private val socket: WebSocket,
    private val messages: LinkedBlockingQueue<String>,
) {
    fun send(text: String) {
        socket.sendText(text, true).join()
    }

    fun nextText(): String =
        messages.poll(Duration.ofSeconds(5).toMillis(), TimeUnit.MILLISECONDS)
            ?: error("timed out waiting for websocket text")

    fun close() {
        socket.sendClose(WebSocket.NORMAL_CLOSURE, "done").join()
    }

    companion object {
        fun connect(uri: String): TestWebSocketClient {
            val messages = LinkedBlockingQueue<String>()
            val listener = object : WebSocket.Listener {
                override fun onText(
                    webSocket: WebSocket,
                    data: CharSequence,
                    last: Boolean,
                ): CompletionStage<*> {
                    if (last) {
                        messages.offer(data.toString())
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
