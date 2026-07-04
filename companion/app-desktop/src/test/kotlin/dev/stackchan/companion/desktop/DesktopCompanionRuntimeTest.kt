package dev.stackchan.companion.desktop

import dev.stackchan.companion.core.SettingsGet
import dev.stackchan.companion.core.SettingsResult
import dev.stackchan.companion.core.SettingsSet
import dev.stackchan.companion.core.SettingsSnapshot
import dev.stackchan.companion.core.decodeControlMessage
import dev.stackchan.companion.core.encodeControlMessage
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.nio.file.Files
import java.nio.file.Path
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

class DesktopCompanionRuntimeTest {
    @Test
    fun runtimeStartsEndpointServerAndPersistsSettings() {
        val storageDir = Files.createTempDirectory("stackchan-desktop-runtime")
        val firstConfig = runtimeConfig(storageDir)

        DesktopCompanionRuntime(firstConfig).use { runtime ->
            runtime.start()
            assertEquals(false, runtime.snapshot().mdnsAdvertised)
            val client = TestWebSocketClient.connect("ws://127.0.0.1:${firstConfig.port}/bridge")

            client.send(
                encodeControlMessage(
                    SettingsSet(
                        version = 1,
                        settings = buildJsonObject {
                            put("display", buildJsonObject {
                                put("brightness", JsonPrimitive(63))
                            })
                        },
                    ),
                ),
            )
            val result = assertIs<SettingsResult>(decodeControlMessage(client.nextText()))

            assertTrue(result.ok)
            client.close()
        }

        val secondConfig = runtimeConfig(storageDir)
        DesktopCompanionRuntime(secondConfig).use { runtime ->
            runtime.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:${secondConfig.port}/bridge")

            client.send(encodeControlMessage(SettingsGet(domains = listOf("display"))))
            val snapshot = assertIs<SettingsSnapshot>(decodeControlMessage(client.nextText()))

            assertEquals(2, snapshot.version)
            assertEquals(
                63,
                snapshot.settings["display"]!!.jsonObject["brightness"]!!.jsonPrimitive.content.toInt(),
            )
            client.close()
        }
    }

    private fun runtimeConfig(storageDir: Path): DesktopCompanionRuntimeConfig =
        DesktopCompanionRuntimeConfig(
            host = "127.0.0.1",
            port = freePort(),
            storageDir = storageDir,
            endpointId = "pc-runtime-test",
            advertiseMdns = false,
        )

    private fun freePort(): Int =
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }

    @Test
    fun runtimeAdvertisesBridgeEndpointWhenMdnsIsEnabled() {
        val config = runtimeConfig(Files.createTempDirectory("stackchan-desktop-mdns")).copy(
            advertiseMdns = true,
            mdnsAddress = InetAddress.getLoopbackAddress(),
            mdnsInstanceName = "stackchan-runtime-mdns-test",
        )

        DesktopCompanionRuntime(config).use { runtime ->
            runtime.start()

            val snapshot = runtime.snapshot()

            assertEquals(true, snapshot.mdnsAdvertised)
            assertEquals("", snapshot.mdnsError)
            assertEquals("pc-runtime-test", snapshot.mdnsEndpoint!!.endpointId)
            assertEquals("pc", snapshot.mdnsEndpoint.endpointKind)
            assertEquals(config.port, snapshot.mdnsEndpoint.port)
            assertTrue("brain_owner" in snapshot.mdnsEndpoint.capabilities)
        }
    }
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
                .get(Duration.ofSeconds(5).toMillis(), TimeUnit.MILLISECONDS)
            socket.request(1)
            return TestWebSocketClient(socket, messages)
        }
    }
}
