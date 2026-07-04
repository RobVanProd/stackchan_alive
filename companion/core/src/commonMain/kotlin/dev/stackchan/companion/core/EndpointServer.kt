package dev.stackchan.companion.core

import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.cio.CIOApplicationEngine
import io.ktor.server.engine.EmbeddedServer
import io.ktor.server.engine.embeddedServer
import io.ktor.server.routing.routing
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.webSocket
import io.ktor.websocket.Frame
import io.ktor.websocket.readText
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class EndpointServerConfig(
    val host: String = "127.0.0.1",
    val port: Int = 8765,
    val path: String = "/bridge",
    val endpointHello: EndpointHello = defaultDesktopEndpointHello(),
    val requestRouter: EndpointRequestRouter = EndpointRequestRouter(),
)

data class EndpointSessionSnapshot(
    val connected: Boolean = false,
    val deviceId: String = "",
    val deviceName: String = "",
    val firmwareVersion: String = "",
    val sampleRate: Int = 0,
    val activeBrainOwner: String? = null,
    val capabilities: List<String> = emptyList(),
    val messagesReceived: Int = 0,
    val lastMessageType: String = "",
    val lastError: String = "",
    val audioBytesReceived: Int = 0,
    val audioBytesSent: Int = 0,
)

private data class AudioTurnState(
    val active: Boolean = false,
    val seq: Int = 0,
    val sampleRate: Int = 16000,
    val bytesReceived: Int = 0,
)

private sealed interface OutboundFrame {
    data class Text(val value: String) : OutboundFrame
    data class Binary(val value: ByteArray) : OutboundFrame
}

class CompanionEndpointServer(
    private val config: EndpointServerConfig,
) : AutoCloseable {
    private val lock = Mutex()
    private var snapshot = EndpointSessionSnapshot()
    private var audioTurn = AudioTurnState()
    private var engine: EmbeddedServer<CIOApplicationEngine, CIOApplicationEngine.Configuration>? = null

    fun start(): CompanionEndpointServer {
        check(engine == null) { "endpoint server already started" }
        engine = embeddedServer(CIO, host = config.host, port = config.port) {
            install(WebSockets)
            routing {
                webSocket(config.path) {
                    updateConnected(true)
                    try {
                        for (frame in incoming) {
                            val responses = when (frame) {
                                is Frame.Text -> handleTextFrame(frame.readText())
                                is Frame.Binary -> handleBinaryFrame(frame.data)
                                else -> emptyList()
                            }
                            responses.forEach { response ->
                                when (response) {
                                    is OutboundFrame.Text -> outgoing.send(Frame.Text(response.value))
                                    is OutboundFrame.Binary -> outgoing.send(Frame.Binary(true, response.value))
                                }
                            }
                        }
                    } catch (_: ClosedReceiveChannelException) {
                        // Normal peer disconnect.
                    } finally {
                        updateConnected(false)
                    }
                }
            }
        }.start(wait = false)
        return this
    }

    suspend fun currentSnapshot(): EndpointSessionSnapshot = lock.withLock { snapshot }

    override fun close() {
        engine?.stop(gracePeriodMillis = 100, timeoutMillis = 1000)
        engine = null
    }

    private suspend fun handleTextFrame(text: String): List<OutboundFrame> {
        return try {
            when (val message = decodeControlMessage(text)) {
                is DeviceHello -> {
                    recordMessage(message)
                    textFrame(config.endpointHello)
                }
                is BridgeHello -> {
                    recordBridgeHello(message)
                    textFrame(config.endpointHello)
                }
                is Heartbeat -> {
                    recordMessageType(message.type)
                    emptyList()
                }
                is UtteranceStart -> {
                    startAudioTurn(message)
                    emptyList()
                }
                is UtteranceAudio -> {
                    appendAudioBytes(message)
                    emptyList()
                }
                is UtteranceEnd -> {
                    finishAudioTurn(message)
                }
                is CancelMessage -> {
                    cancelAudioTurn(message)
                    emptyList()
                }
                is OwnerStatus -> {
                    recordOwnerStatus(message)
                    abortAudioTurnIfOwnerLost(message)
                }
                else -> {
                    recordMessageType(message.type)
                    config.requestRouter.handle(message)?.let { textFrame(it) }.orEmpty()
                }
            }
        } catch (error: RuntimeException) {
            recordError(error.message ?: error::class.simpleName.orEmpty())
            textFrame(
                BridgeError(
                    code = "bad_control_message",
                    detail = "Control message could not be decoded.",
                    recoverable = true,
                ),
            )
        }
    }

    private suspend fun handleBinaryFrame(bytes: ByteArray): List<OutboundFrame> {
        lock.withLock {
            if (audioTurn.active) {
                audioTurn = audioTurn.copy(bytesReceived = audioTurn.bytesReceived + bytes.size)
                snapshot = snapshot.copy(
                    messagesReceived = snapshot.messagesReceived + 1,
                    lastMessageType = "binary_audio",
                    lastError = "",
                    audioBytesReceived = snapshot.audioBytesReceived + bytes.size,
                )
            }
        }
        return emptyList()
    }

    private suspend fun updateConnected(connected: Boolean) {
        lock.withLock {
            snapshot = if (connected) {
                snapshot.copy(connected = true, lastError = "")
            } else {
                snapshot.copy(connected = false)
            }
        }
    }

    private suspend fun recordMessage(message: DeviceHello) {
        lock.withLock {
            snapshot = snapshot.copy(
                deviceId = message.deviceId,
                deviceName = message.deviceName,
                firmwareVersion = message.firmwareVersion,
                sampleRate = message.sampleRate,
                activeBrainOwner = message.activeBrainOwner,
                capabilities = message.capabilities,
                messagesReceived = snapshot.messagesReceived + 1,
                lastMessageType = message.type,
                lastError = "",
            )
        }
    }

    private suspend fun recordBridgeHello(message: BridgeHello) {
        lock.withLock {
            snapshot = snapshot.copy(
                deviceId = message.session,
                messagesReceived = snapshot.messagesReceived + 1,
                lastMessageType = message.type,
                lastError = "",
            )
        }
    }

    private suspend fun recordMessageType(type: String) {
        lock.withLock {
            snapshot = snapshot.copy(
                messagesReceived = snapshot.messagesReceived + 1,
                lastMessageType = type,
                lastError = "",
            )
        }
    }

    private suspend fun startAudioTurn(message: UtteranceStart) {
        lock.withLock {
            audioTurn = AudioTurnState(
                active = true,
                seq = message.seq,
                sampleRate = message.sampleRate,
            )
            snapshot = snapshot.copy(
                messagesReceived = snapshot.messagesReceived + 1,
                lastMessageType = message.type,
                lastError = "",
            )
        }
    }

    @OptIn(ExperimentalEncodingApi::class)
    private suspend fun appendAudioBytes(message: UtteranceAudio) {
        val bytes = Base64.Default.decode(message.pcmB64)
        lock.withLock {
            val nextBytes = audioTurn.bytesReceived + bytes.size
            audioTurn = audioTurn.copy(active = true, seq = message.seq, bytesReceived = nextBytes)
            snapshot = snapshot.copy(
                messagesReceived = snapshot.messagesReceived + 1,
                lastMessageType = message.type,
                lastError = "",
                audioBytesReceived = snapshot.audioBytesReceived + bytes.size,
            )
        }
    }

    private suspend fun finishAudioTurn(message: UtteranceEnd): List<OutboundFrame> {
        val turn = lock.withLock {
            val current = audioTurn.copy(active = audioTurn.active, seq = message.seq.takeIf { it != 0 } ?: audioTurn.seq)
            audioTurn = AudioTurnState()
            snapshot = snapshot.copy(
                messagesReceived = snapshot.messagesReceived + 1,
                lastMessageType = message.type,
                lastError = "",
            )
            current
        }
        if (!turn.active) {
            recordError("audio turn is not active")
            return textFrame(
                BridgeError(
                    seq = message.seq,
                    code = "audio_turn_not_active",
                    detail = "No active audio turn is available to finish.",
                    recoverable = true,
                ),
            )
        }
        val seq = message.seq
        val responseText = message.transcript
            ?.takeIf { it.isNotBlank() }
            ?: message.text?.takeIf { it.isNotBlank() }
            ?: "Fake audio turn received ${turn.bytesReceived} bytes at ${turn.sampleRate}Hz."
        val pcm = fakePcm16(responseText)
        val chunkSize = 512
        val chunks = pcm.asIterable().chunked(chunkSize).map { it.toByteArray() }
        recordAudioBytesSent(pcm.size)

        return buildList {
            addAll(
                textFrames(
                    Thinking(seq = seq),
                    ResponseStart(
                        seq = seq,
                        intent = "fake_audio_turn",
                        text = responseText,
                        arousal = 0.42,
                        valence = 0.64,
                    ),
                    AudioStreamStart(
                        seq = seq,
                        format = "pcm16",
                        sampleRate = 24000,
                        audioBytes = pcm.size,
                        chunkBytes = chunkSize,
                        chunks = chunks.size,
                    ),
                ),
            )
            chunks.forEach { chunk -> add(OutboundFrame.Binary(chunk)) }
            addAll(
                textFrames(
                    AudioFrame(seq = seq, env = 0.35, viseme = "aa", durationMs = 120),
                    AudioFrame(seq = seq, env = 0.0, viseme = "neutral", durationMs = 60, final = true),
                    AudioStreamEnd(seq = seq, audioBytes = pcm.size, chunks = chunks.size),
                    ResponseEnd(seq = seq),
                ),
            )
        }
    }

    private suspend fun recordOwnerStatus(message: OwnerStatus) {
        lock.withLock {
            snapshot = snapshot.copy(
                activeBrainOwner = message.activeBrainOwner.takeIf { it.isNotBlank() },
                messagesReceived = snapshot.messagesReceived + 1,
                lastMessageType = message.type,
                lastError = "",
            )
        }
    }

    private suspend fun abortAudioTurnIfOwnerLost(message: OwnerStatus): List<OutboundFrame> {
        val shouldAbort = lock.withLock {
            val active = audioTurn.active
            val stillOwner = message.activeBrainOwner == config.endpointHello.endpointId && message.state == "claimed"
            if (active && !stillOwner) {
                audioTurn = AudioTurnState()
                true
            } else {
                false
            }
        }
        return if (shouldAbort) {
            textFrame(
                BridgeError(
                    code = "audio_turn_aborted",
                    detail = "Audio turn aborted because this endpoint lost brain ownership.",
                    recoverable = true,
                ),
            )
        } else {
            emptyList()
        }
    }

    private suspend fun cancelAudioTurn(message: CancelMessage) {
        lock.withLock {
            audioTurn = AudioTurnState()
            snapshot = snapshot.copy(
                messagesReceived = snapshot.messagesReceived + 1,
                lastMessageType = message.type,
                lastError = "",
            )
        }
    }

    private suspend fun recordAudioBytesSent(bytes: Int) {
        lock.withLock {
            snapshot = snapshot.copy(audioBytesSent = snapshot.audioBytesSent + bytes)
        }
    }

    private suspend fun recordError(message: String) {
        lock.withLock {
            snapshot = snapshot.copy(lastError = message)
        }
    }

    private fun textFrame(message: BridgeMessage): List<OutboundFrame> =
        listOf(OutboundFrame.Text(encodeControlMessage(message)))

    private fun textFrames(vararg messages: BridgeMessage): List<OutboundFrame> =
        messages.map { OutboundFrame.Text(encodeControlMessage(it)) }

    private fun fakePcm16(seed: String): ByteArray {
        val bytes = seed.encodeToByteArray()
        return ByteArray(1024) { index ->
            (bytes[index % bytes.size].toInt() + index).toByte()
        }
    }
}
