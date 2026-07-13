package dev.stackchan.companion.core

import java.net.ServerSocket
import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.nio.ByteBuffer
import java.time.Duration
import java.util.Base64
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionStage
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.delay
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
            client.sendRobotHello()
            assertIs<EndpointHello>(decodeControlMessage(client.nextText()))

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

    @Test
    fun endpointServerRoutesOwnerHandoffRequests() {
        val port = freePort()
        val registry = TrustedEndpointRegistry()
        registry.upsert(
            TrustedEndpoint(
                endpointId = "phone-rob-01",
                endpointKind = "android",
                publicKeyFingerprint = "sha256:1111222233334444",
                priority = 80,
                autoConnect = true,
                capabilities = listOf("brain_owner"),
            ),
        )
        val router = EndpointRequestRouter(trustedEndpointRegistry = registry)
        CompanionEndpointServer(EndpointServerConfig(port = port, requestRouter = router)).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")

            client.send(encodeControlMessage(ClaimBrain(endpointId = "phone-rob-01", reason = "mobile brain online")))
            val claimed = assertIs<OwnerStatus>(decodeControlMessage(client.nextText()))
            client.send(encodeControlMessage(ReleaseBrain(endpointId = "phone-rob-01", reason = "operator release")))
            val released = assertIs<OwnerStatus>(decodeControlMessage(client.nextText()))

            assertEquals("phone-rob-01", claimed.activeBrainOwner)
            assertEquals("claimed", claimed.state)
            assertEquals("", released.activeBrainOwner)
            assertEquals("offline", released.state)
            client.close()
        }
    }

    @Test
    fun endpointServerRoutesDiagnosticsRequests() {
        val port = freePort()
        CompanionEndpointServer(EndpointServerConfig(port = port)).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")

            client.send(encodeControlMessage(DiagnosticsRequest(domains = listOf("bridge", "audio"))))
            val snapshot = assertIs<DiagnosticsSnapshot>(decodeControlMessage(client.nextText()))

            assertEquals("stackchan.bridge.v1", snapshot.bridge["protocol"]!!.jsonPrimitive.content)
            assertEquals("fake", snapshot.audio!!.jsonObject["engine"]!!.jsonPrimitive.content)
            assertEquals(null, snapshot.model)
            client.close()
        }
    }

    @Test
    fun endpointServerRunsDeterministicFakeAudioTurn() = runBlocking {
        val port = freePort()
        CompanionEndpointServer(EndpointServerConfig(port = port)).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")
            client.sendRobotHello()
            assertIs<EndpointHello>(decodeControlMessage(client.nextText()))

            client.send(encodeControlMessage(UtteranceStart(seq = 7, sampleRate = 16000)))
            client.sendBinary(ByteArray(256) { 1 })
            client.send(
                encodeControlMessage(
                    UtteranceAudio(
                        seq = 7,
                        pcmB64 = Base64.getEncoder().encodeToString(ByteArray(128) { 2 }),
                    ),
                ),
            )
            client.send(encodeControlMessage(UtteranceEnd(seq = 7, transcript = "Bench audio received")))

            val thinking = assertIs<Thinking>(decodeControlMessage(client.nextText()))
            val response = assertIs<ResponseStart>(decodeControlMessage(client.nextText()))
            val streamStart = assertIs<AudioStreamStart>(decodeControlMessage(client.nextText()))
            val firstChunk = client.nextBinary()
            val secondChunk = client.nextBinary()
            val firstMouth = assertIs<AudioFrame>(decodeControlMessage(client.nextText()))
            val finalMouth = assertIs<AudioFrame>(decodeControlMessage(client.nextText()))
            val streamEnd = assertIs<AudioStreamEnd>(decodeControlMessage(client.nextText()))
            val responseEnd = assertIs<ResponseEnd>(decodeControlMessage(client.nextText()))
            val snapshot = server.currentSnapshot()

            assertEquals(7, thinking.seq)
            assertEquals("fake_audio_turn", response.intent)
            assertEquals("Bench audio received", response.text)
            assertEquals("pcm16", streamStart.format)
            assertEquals(24000, streamStart.sampleRate)
            assertEquals(1024, streamStart.audioBytes)
            assertEquals(512, streamStart.chunkBytes)
            assertEquals(2, streamStart.chunks)
            assertEquals(512, firstChunk.size)
            assertEquals(512, secondChunk.size)
            assertEquals("aa", firstMouth.viseme)
            assertEquals(true, finalMouth.final)
            assertEquals(1024, streamEnd.audioBytes)
            assertEquals(2, streamEnd.chunks)
            assertEquals(7, responseEnd.seq)
            assertEquals(384, snapshot.audioBytesReceived)
            assertEquals(1024, snapshot.audioBytesSent)
            assertEquals("utterance_end", snapshot.lastMessageType)
            client.close()
        }
    }

    @Test
    fun endpointServerSendsSubmittedTextTurnToConnectedRobot() = runBlocking {
        val port = freePort()
        CompanionEndpointServer(EndpointServerConfig(port = port)).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")

            client.send(
                encodeControlMessage(
                    DeviceHello(
                        deviceId = "stackchan-001",
                        deviceName = "Stackchan Alive Bench",
                        firmwareVersion = "dev-c2",
                    ),
                ),
            )
            assertIs<EndpointHello>(decodeControlMessage(client.nextText()))

            val submit = server.submitTextTurn("Hello from the phone")

            val thinking = assertIs<Thinking>(decodeControlMessage(client.nextText()))
            val response = assertIs<ResponseStart>(decodeControlMessage(client.nextText()))
            val streamStart = assertIs<AudioStreamStart>(decodeControlMessage(client.nextText()))
            val firstChunk = client.nextBinary()
            val secondChunk = client.nextBinary()
            assertIs<AudioFrame>(decodeControlMessage(client.nextText()))
            val finalMouth = assertIs<AudioFrame>(decodeControlMessage(client.nextText()))
            val streamEnd = assertIs<AudioStreamEnd>(decodeControlMessage(client.nextText()))
            val responseEnd = assertIs<ResponseEnd>(decodeControlMessage(client.nextText()))
            val snapshot = server.currentSnapshot()

            assertTrue(submit.accepted)
            assertEquals(submit.seq, thinking.seq)
            assertEquals("app_text_turn", response.intent)
            assertEquals("Hello from the phone", response.text)
            assertEquals("pcm16", streamStart.format)
            assertEquals(512, firstChunk.size)
            assertEquals(512, secondChunk.size)
            assertEquals(true, finalMouth.final)
            assertEquals(1024, streamEnd.audioBytes)
            assertEquals(submit.seq, responseEnd.seq)
            assertEquals("app_text_turn", snapshot.lastMessageType)
            assertEquals(1, snapshot.textTurnsSubmitted)
            assertEquals("Hello from the phone", snapshot.lastTextTurn)
            assertEquals(1024, snapshot.audioBytesSent)
            client.close()
        }
    }

    @Test
    fun endpointServerRoutesSubmittedTextTurnsThroughConfiguredBrainEngine() = runBlocking {
        val port = freePort()
        val engine = BrainTurnEngine { request ->
            BrainTurnResponse(
                text = "engine saw ${request.source} ${request.text}",
                intent = "engine_text_turn",
                arousal = 0.7,
                valence = 0.8,
                audioPcm16 = ByteArray(256) { 9 },
                audioSampleRate = 16000,
            )
        }
        CompanionEndpointServer(EndpointServerConfig(port = port, brainTurnEngine = engine)).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")
            client.sendRobotHello()
            assertIs<EndpointHello>(decodeControlMessage(client.nextText()))

            val submit = server.submitTextTurn("hello model")

            assertIs<Thinking>(decodeControlMessage(client.nextText()))
            val response = assertIs<ResponseStart>(decodeControlMessage(client.nextText()))
            val streamStart = assertIs<AudioStreamStart>(decodeControlMessage(client.nextText()))
            val chunk = client.nextBinary()
            assertIs<AudioFrame>(decodeControlMessage(client.nextText()))
            assertIs<AudioFrame>(decodeControlMessage(client.nextText()))
            val streamEnd = assertIs<AudioStreamEnd>(decodeControlMessage(client.nextText()))
            assertIs<ResponseEnd>(decodeControlMessage(client.nextText()))

            assertTrue(submit.accepted)
            assertEquals("engine_text_turn", response.intent)
            assertEquals("engine saw APP_TEXT hello model", response.text)
            assertEquals(0.7, response.arousal)
            assertEquals(0.8, response.valence)
            assertEquals(16000, streamStart.sampleRate)
            assertEquals(256, streamStart.audioBytes)
            assertEquals(256, chunk.size)
            assertEquals(256, streamEnd.audioBytes)
            client.close()
        }
    }

    @Test
    fun endpointServerRoutesAudioTurnsThroughConfiguredBrainEngine() = runBlocking {
        val port = freePort()
        val engine = BrainTurnEngine { request ->
            BrainTurnResponse(
                text = "audio bytes=${request.audioBytesReceived} sr=${request.inputSampleRate} text=${request.text}",
                intent = "engine_audio_turn",
            )
        }
        CompanionEndpointServer(EndpointServerConfig(port = port, brainTurnEngine = engine)).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")
            client.sendRobotHello()
            assertIs<EndpointHello>(decodeControlMessage(client.nextText()))

            client.send(encodeControlMessage(UtteranceStart(seq = 17, sampleRate = 16000)))
            client.sendBinary(ByteArray(32) { 1 })
            client.send(
                encodeControlMessage(
                    UtteranceAudio(
                        seq = 17,
                        pcmB64 = Base64.getEncoder().encodeToString(ByteArray(48) { 2 }),
                    ),
                ),
            )
            client.send(encodeControlMessage(UtteranceEnd(seq = 17, transcript = "robot transcript")))

            assertIs<Thinking>(decodeControlMessage(client.nextText()))
            val response = assertIs<ResponseStart>(decodeControlMessage(client.nextText()))

            assertEquals("engine_audio_turn", response.intent)
            assertEquals("audio bytes=80 sr=16000 text=robot transcript", response.text)
            client.close()
        }
    }

    @Test
    fun endpointServerRejectsSubmittedTextTurnWithoutRobotSession() = runBlocking {
        CompanionEndpointServer(EndpointServerConfig(port = freePort())).use { server ->
            server.start()

            val submit = server.submitTextTurn("Hello?")

            assertEquals(false, submit.accepted)
            assertEquals("No Stack-chan robot session is connected.", submit.detail)
        }
    }

    @Test
    fun endpointServerRejectsSubmittedTextTurnBeforeRobotHello() = runBlocking {
        val port = freePort()
        CompanionEndpointServer(EndpointServerConfig(port = port)).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")
            server.waitForSnapshot { it.connected && !it.robotHelloReceived }

            val submit = server.submitTextTurn("Hello before hello")
            val snapshot = server.currentSnapshot()

            assertEquals(false, submit.accepted)
            assertEquals("Stack-chan has not completed the bridge hello yet.", submit.detail)
            assertTrue(snapshot.connected)
            assertEquals(false, snapshot.robotHelloReceived)
            client.close()
        }
    }

    @Test
    fun endpointServerSendsProtectedSettingsSetToConnectedRobot() = runBlocking {
        val port = freePort()
        CompanionEndpointServer(EndpointServerConfig(port = port)).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")
            client.sendRobotHello()
            assertIs<EndpointHello>(decodeControlMessage(client.nextText()))

            val submitted = server.submitProtectedControl(
                SettingsSet(
                    version = 7,
                    settings = buildJsonObject {
                        put("display", buildJsonObject {
                            put("reduced_motion", JsonPrimitive(true))
                        })
                    },
                ),
            )
            val robotFrame = assertIs<SettingsSet>(decodeControlMessage(client.nextText()))
            client.send(encodeControlMessage(SettingsResult(ok = true, version = 8)))
            server.waitForSnapshot { it.lastMessageType == "settings_result" }
            val snapshot = server.currentSnapshot()

            assertTrue(submitted.accepted)
            assertEquals("settings_set", submitted.messageType)
            assertEquals(7, robotFrame.version)
            assertEquals(
                true,
                robotFrame.settings["display"]!!.jsonObject["reduced_motion"]!!.jsonPrimitive.content.toBoolean(),
            )
            assertEquals("settings_result", snapshot.lastMessageType)
            client.close()
        }
    }

    @Test
    fun endpointServerSendsProtectedBrainClaimAndReleaseToConnectedRobot() = runBlocking {
        val port = freePort()
        CompanionEndpointServer(
            EndpointServerConfig(
                port = port,
                endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            ),
        ).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")
            client.sendRobotHello()
            assertIs<EndpointHello>(decodeControlMessage(client.nextText()))

            val claim = server.submitProtectedControl(
                ClaimBrain(endpointId = "phone-rob-01", reason = "operator selected phone brain"),
            )
            val claimFrame = assertIs<ClaimBrain>(decodeControlMessage(client.nextText()))
            client.send(
                encodeControlMessage(
                    OwnerStatus(
                        activeBrainOwner = "phone-rob-01",
                        ownerKind = "android",
                        state = "claimed",
                    ),
                ),
            )
            server.waitForSnapshot { it.activeBrainOwner == "phone-rob-01" }

            val release = server.submitProtectedControl(
                ReleaseBrain(endpointId = "phone-rob-01", reason = "operator released phone brain"),
            )
            val releaseFrame = assertIs<ReleaseBrain>(decodeControlMessage(client.nextText()))
            client.send(
                encodeControlMessage(
                    OwnerStatus(
                        activeBrainOwner = "",
                        ownerKind = "none",
                        state = "released",
                    ),
                ),
            )
            server.waitForSnapshot { it.lastMessageType == "owner_status" && it.activeBrainOwner == null }
            val snapshot = server.currentSnapshot()

            assertTrue(claim.accepted)
            assertEquals("claim_brain", claim.messageType)
            assertEquals("phone-rob-01", claimFrame.endpointId)
            assertTrue(release.accepted)
            assertEquals("release_brain", release.messageType)
            assertEquals("phone-rob-01", releaseFrame.endpointId)
            assertEquals(null, snapshot.activeBrainOwner)
            client.close()
        }
    }

    @Test
    fun endpointServerRejectsProtectedControlBeforeRobotHello() = runBlocking {
        val port = freePort()
        CompanionEndpointServer(EndpointServerConfig(port = port)).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")
            server.waitForSnapshot { it.connected && !it.robotHelloReceived }

            val submitted = server.submitProtectedControl(
                ClaimBrain(endpointId = "pc-companion-c0", reason = "too early"),
            )

            assertEquals(false, submitted.accepted)
            assertEquals("claim_brain", submitted.messageType)
            assertEquals("Stack-chan has not completed the bridge hello yet.", submitted.detail)
            client.close()
        }
    }

    @Test
    fun endpointServerRejectsAudioAndSettingsWritesBeforeRobotHello() = runBlocking {
        val port = freePort()
        CompanionEndpointServer(EndpointServerConfig(port = port)).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")
            server.waitForSnapshot { it.connected && !it.robotHelloReceived }

            client.send(encodeControlMessage(UtteranceStart(seq = 11, sampleRate = 16000)))
            val audioError = assertIs<BridgeError>(decodeControlMessage(client.nextText()))
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
            val settingsError = assertIs<BridgeError>(decodeControlMessage(client.nextText()))
            val snapshot = server.currentSnapshot()

            assertEquals("robot_hello_required", audioError.code)
            assertEquals(11, audioError.seq)
            assertEquals("robot_hello_required", settingsError.code)
            assertEquals(false, snapshot.robotHelloReceived)
            assertEquals("robot hello is required before protected bridge writes", snapshot.lastError)
            client.close()
        }
    }

    @Test
    fun endpointServerDoesNotFinishCanceledAudioTurn() = runBlocking {
        val port = freePort()
        CompanionEndpointServer(EndpointServerConfig(port = port)).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")
            client.sendRobotHello()
            assertIs<EndpointHello>(decodeControlMessage(client.nextText()))

            client.send(encodeControlMessage(UtteranceStart(seq = 8, sampleRate = 16000)))
            client.sendBinary(ByteArray(64) { 3 })
            client.send(encodeControlMessage(CancelMessage(seq = 8, reason = "barge_in")))
            client.send(encodeControlMessage(UtteranceEnd(seq = 8, transcript = "should not answer")))

            val error = assertIs<BridgeError>(decodeControlMessage(client.nextText()))
            val snapshot = server.currentSnapshot()

            assertEquals("audio_turn_not_active", error.code)
            assertEquals(8, error.seq)
            assertEquals(true, error.recoverable)
            assertEquals(64, snapshot.audioBytesReceived)
            assertEquals(0, snapshot.audioBytesSent)
            assertEquals("audio turn is not active", snapshot.lastError)
            client.close()
        }
    }

    @Test
    fun endpointServerAbortsAudioTurnWhenOwnerChanges() = runBlocking {
        val port = freePort()
        CompanionEndpointServer(
            EndpointServerConfig(
                port = port,
                endpointHello = defaultDesktopEndpointHello(endpointId = "pc-test-owner"),
            ),
        ).use { server ->
            server.start()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:$port/bridge")
            client.sendRobotHello()
            assertIs<EndpointHello>(decodeControlMessage(client.nextText()))

            client.send(encodeControlMessage(UtteranceStart(seq = 9, sampleRate = 16000)))
            client.sendBinary(ByteArray(96) { 4 })
            client.send(
                encodeControlMessage(
                    OwnerStatus(
                        activeBrainOwner = "phone-owner",
                        ownerKind = "android",
                        state = "claimed",
                    ),
                ),
            )
            val ownerLoss = assertIs<BridgeError>(decodeControlMessage(client.nextText()))
            client.send(encodeControlMessage(UtteranceEnd(seq = 9, transcript = "should not answer")))
            val finishError = assertIs<BridgeError>(decodeControlMessage(client.nextText()))
            val snapshot = server.currentSnapshot()

            assertEquals("audio_turn_aborted", ownerLoss.code)
            assertEquals("audio_turn_not_active", finishError.code)
            assertEquals("phone-owner", snapshot.activeBrainOwner)
            assertEquals(96, snapshot.audioBytesReceived)
            assertEquals(0, snapshot.audioBytesSent)
            client.close()
        }
    }

    private fun freePort(): Int =
        ServerSocket(0).use { it.localPort }

    private suspend fun CompanionEndpointServer.waitForSnapshot(
        timeout: Duration = Duration.ofSeconds(5),
        predicate: (EndpointSessionSnapshot) -> Boolean,
    ): EndpointSessionSnapshot {
        val deadline = System.nanoTime() + timeout.toNanos()
        var snapshot = currentSnapshot()
        while (System.nanoTime() < deadline) {
            if (predicate(snapshot)) {
                return snapshot
            }
            delay(10)
            snapshot = currentSnapshot()
        }
        error("timed out waiting for endpoint snapshot: $snapshot")
    }
}

private class TestWebSocketClient private constructor(
    private val socket: WebSocket,
    private val messages: LinkedBlockingQueue<String>,
    private val binaryMessages: LinkedBlockingQueue<ByteArray>,
) {
    fun send(text: String) {
        socket.sendText(text, true).join()
    }

    fun sendBinary(bytes: ByteArray) {
        socket.sendBinary(ByteBuffer.wrap(bytes), true).join()
    }

    fun sendRobotHello() {
        send(
            encodeControlMessage(
                DeviceHello(
                    deviceId = "stackchan-001",
                    deviceName = "Stackchan Alive Bench",
                    firmwareVersion = "dev-c2",
                ),
            ),
        )
    }

    fun nextText(): String =
        messages.poll(Duration.ofSeconds(5).toMillis(), TimeUnit.MILLISECONDS)
            ?: error("timed out waiting for websocket text")

    fun nextBinary(): ByteArray =
        binaryMessages.poll(Duration.ofSeconds(5).toMillis(), TimeUnit.MILLISECONDS)
            ?: error("timed out waiting for websocket binary")

    fun close() {
        socket.sendClose(WebSocket.NORMAL_CLOSURE, "done").join()
    }

    companion object {
        fun connect(uri: String): TestWebSocketClient {
            val messages = LinkedBlockingQueue<String>()
            val binaryMessages = LinkedBlockingQueue<ByteArray>()
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

                override fun onBinary(
                    webSocket: WebSocket,
                    data: ByteBuffer,
                    last: Boolean,
                ): CompletionStage<*> {
                    if (last) {
                        val bytes = ByteArray(data.remaining())
                        data.get(bytes)
                        binaryMessages.offer(bytes)
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
            return TestWebSocketClient(socket, messages, binaryMessages)
        }
    }
}
