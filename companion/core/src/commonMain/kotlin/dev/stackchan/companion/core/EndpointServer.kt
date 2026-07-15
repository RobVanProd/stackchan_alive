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
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class EndpointServerConfig(
    val host: String = "127.0.0.1",
    val port: Int = 8765,
    val path: String = "/bridge",
    val endpointHello: EndpointHello = defaultDesktopEndpointHello(),
    val requestRouter: EndpointRequestRouter = EndpointRequestRouter(),
    val brainTurnEngine: BrainTurnEngine = DeterministicBrainTurnEngine,
)

data class EndpointSessionSnapshot(
    val connected: Boolean = false,
    val robotHelloReceived: Boolean = false,
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
    val textTurnsSubmitted: Int = 0,
    val lastTextTurn: String = "",
    val networkProfile: String = "",
)

data class TextTurnSubmitResult(
    val accepted: Boolean,
    val seq: Int = 0,
    val responseText: String = "",
    val detail: String,
)

data class ProtectedControlSubmitResult(
    val accepted: Boolean,
    val messageType: String = "",
    val detail: String,
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

private data class OutboundTurn(
    val seq: Int,
    val text: String,
    val audioBytes: Int,
    val frames: List<OutboundFrame>,
)

private sealed interface OutboundItem {
    data class Turn(val value: OutboundTurn) : OutboundItem
    data class Control(val message: BridgeMessage, val frame: OutboundFrame.Text) : OutboundItem
}

class CompanionEndpointServer(
    private val config: EndpointServerConfig,
) : AutoCloseable {
    private val lock = Mutex()
    private var snapshot = EndpointSessionSnapshot()
    private var audioTurn = AudioTurnState()
    private var outboundItems: Channel<OutboundItem>? = null
    private var nextLocalSeq = 10_000
    private var engine: EmbeddedServer<CIOApplicationEngine, CIOApplicationEngine.Configuration>? = null

    fun start(): CompanionEndpointServer {
        check(engine == null) { "endpoint server already started" }
        engine = embeddedServer(CIO, host = config.host, port = config.port) {
            install(WebSockets)
            routing {
                webSocket(config.path) {
                    val outboundChannel = Channel<OutboundItem>(Channel.BUFFERED)
                    setOutboundItems(outboundChannel)
                    val senderJob = launch {
                        for (item in outboundChannel) {
                            when (item) {
                                is OutboundItem.Turn -> {
                                    item.value.frames.forEach { response ->
                                        sendOutboundFrame(response)
                                    }
                                    recordSubmittedTextTurn(item.value)
                                }
                                is OutboundItem.Control -> {
                                    sendOutboundFrame(item.frame)
                                    recordSubmittedControlMessage(item.message)
                                }
                            }
                        }
                    }
                    updateConnected(true)
                    try {
                        for (frame in incoming) {
                            val responses = when (frame) {
                                is Frame.Text -> handleTextFrame(frame.readText())
                                is Frame.Binary -> handleBinaryFrame(frame.data)
                                else -> emptyList()
                            }
                            responses.forEach { response ->
                                sendOutboundFrame(response)
                            }
                        }
                    } catch (_: ClosedReceiveChannelException) {
                        // Normal peer disconnect.
                    } finally {
                        clearOutboundItems(outboundChannel)
                        outboundChannel.close()
                        senderJob.cancel()
                        updateConnected(false)
                    }
                }
            }
        }.start(wait = false)
        return this
    }

    suspend fun currentSnapshot(): EndpointSessionSnapshot = lock.withLock { snapshot }

    suspend fun submitTextTurn(text: String): TextTurnSubmitResult {
        val cleanedText = text.trim()
        if (cleanedText.isBlank()) {
            return TextTurnSubmitResult(
                accepted = false,
                detail = "Text turn is empty.",
            )
        }
        val prepared = lock.withLock {
            val channel = outboundItems
            if (!snapshot.connected || channel == null) {
                return TextTurnSubmitResult(
                    accepted = false,
                    detail = "No Stack-chan robot session is connected.",
                )
            }
            if (!snapshot.robotHelloReceived) {
                return TextTurnSubmitResult(
                    accepted = false,
                    detail = "Stack-chan has not completed the bridge hello yet.",
                )
            }
            nextLocalSeq += 1
            val request = BrainTurnRequest(
                seq = nextLocalSeq,
                text = cleanedText,
                source = BrainTurnSource.APP_TEXT,
                deviceId = snapshot.deviceId,
                activeBrainOwner = snapshot.activeBrainOwner,
            )
            channel to request
        }
        val response = runCatching { config.brainTurnEngine.respond(prepared.second) }
            .getOrElse { error ->
                recordError(error.message ?: error::class.simpleName.orEmpty())
                return TextTurnSubmitResult(
                    accepted = false,
                    detail = "Brain turn engine failed before sending the text turn.",
                )
            }
        val turn = buildResponseTurn(
            seq = prepared.second.seq,
            response = response,
            fallbackIntent = "app_text_turn",
        )
        val sent = prepared.first.trySend(OutboundItem.Turn(turn)).isSuccess
        return if (sent) {
            TextTurnSubmitResult(
                accepted = true,
                seq = turn.seq,
                responseText = turn.text,
                detail = "Text turn sent to the connected Stack-chan session.",
            )
        } else {
            TextTurnSubmitResult(
                accepted = false,
                detail = "Stack-chan session is no longer accepting text turns.",
            )
        }
    }

    suspend fun submitProtectedControl(message: BridgeMessage): ProtectedControlSubmitResult {
        require(message is SettingsSet || message is ClaimBrain || message is ReleaseBrain || message is WifiProfileUse) {
            "protected control message must be settings_set, claim_brain, release_brain, or wifi_profile_use"
        }
        val prepared = lock.withLock {
            val channel = outboundItems
            if (!snapshot.connected || channel == null) {
                return ProtectedControlSubmitResult(
                    accepted = false,
                    messageType = message.type,
                    detail = "No Stack-chan robot session is connected.",
                )
            }
            if (!snapshot.robotHelloReceived) {
                return ProtectedControlSubmitResult(
                    accepted = false,
                    messageType = message.type,
                    detail = "Stack-chan has not completed the bridge hello yet.",
                )
            }
            channel to OutboundItem.Control(
                message = message,
                frame = OutboundFrame.Text(encodeControlMessage(message)),
            )
        }
        val sent = prepared.first.trySend(prepared.second).isSuccess
        return if (sent) {
            ProtectedControlSubmitResult(
                accepted = true,
                messageType = message.type,
                detail = "Protected control message `${message.type}` sent to the connected Stack-chan session.",
            )
        } else {
            ProtectedControlSubmitResult(
                accepted = false,
                messageType = message.type,
                detail = "Stack-chan session is no longer accepting protected control messages.",
            )
        }
    }

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
                    recordHeartbeat(message)
                    emptyList()
                }
                is UtteranceStart -> {
                    if (robotHelloMissing()) {
                        robotHelloRequiredError(seq = message.seq)
                    } else {
                        startAudioTurn(message)
                        emptyList()
                    }
                }
                is UtteranceAudio -> {
                    if (robotHelloMissing()) {
                        robotHelloRequiredError(seq = message.seq)
                    } else {
                        appendAudioBytes(message)
                        emptyList()
                    }
                }
                is UtteranceEnd -> {
                    if (robotHelloMissing()) {
                        robotHelloRequiredError(seq = message.seq)
                    } else {
                        finishAudioTurn(message)
                    }
                }
                is CancelMessage -> {
                    cancelAudioTurn(message)
                    emptyList()
                }
                is OwnerStatus -> {
                    recordOwnerStatus(message)
                    abortAudioTurnIfOwnerLost(message)
                }
                is WifiProfileUseResult -> {
                    recordWifiProfileUseResult(message)
                    emptyList()
                }
                else -> {
                    recordMessageType(message.type)
                    if (message is SettingsSet && robotHelloMissing()) {
                        robotHelloRequiredError()
                    } else {
                        config.requestRouter.handle(message)?.let { textFrame(it) }.orEmpty()
                    }
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
        if (robotHelloMissing()) {
            return robotHelloRequiredError()
        }
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
                EndpointSessionSnapshot(connected = true)
            } else {
                snapshot.copy(connected = false, robotHelloReceived = false)
            }
        }
    }

    private suspend fun recordMessage(message: DeviceHello) {
        lock.withLock {
            snapshot = snapshot.copy(
                deviceId = message.deviceId,
                robotHelloReceived = true,
                deviceName = message.deviceName,
                firmwareVersion = message.firmwareVersion,
                sampleRate = message.sampleRate,
                activeBrainOwner = message.activeBrainOwner,
                capabilities = message.capabilities,
                networkProfile = message.networkProfile.ifBlank { snapshot.networkProfile },
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

    private suspend fun recordHeartbeat(message: Heartbeat) {
        lock.withLock {
            snapshot = snapshot.copy(
                messagesReceived = snapshot.messagesReceived + 1,
                lastMessageType = message.type,
                lastError = "",
                networkProfile = message.networkProfile.ifBlank { snapshot.networkProfile },
            )
        }
    }

    private suspend fun recordWifiProfileUseResult(message: WifiProfileUseResult) {
        lock.withLock {
            snapshot = snapshot.copy(
                messagesReceived = snapshot.messagesReceived + 1,
                lastMessageType = message.type,
                lastError = if (message.accepted) "" else "Wi-Fi profile switch was rejected.",
                networkProfile = if (message.accepted) message.profile else snapshot.networkProfile,
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
        val requestText = message.transcript
            ?.takeIf { it.isNotBlank() }
            ?: message.text?.takeIf { it.isNotBlank() }
            ?: ""
        val request = lock.withLock {
            BrainTurnRequest(
                seq = seq,
                text = requestText,
                source = BrainTurnSource.ROBOT_AUDIO,
                audioBytesReceived = turn.bytesReceived,
                inputSampleRate = turn.sampleRate,
                deviceId = snapshot.deviceId,
                activeBrainOwner = snapshot.activeBrainOwner,
            )
        }
        val response = runCatching { config.brainTurnEngine.respond(request) }
            .getOrElse { error ->
                val detail = error.message ?: error::class.simpleName.orEmpty()
                recordError(detail)
                return textFrame(
                    BridgeError(
                        seq = seq,
                        code = "brain_turn_failed",
                        detail = "Brain turn engine failed before a response could be sent.",
                        recoverable = true,
                    ),
                )
            }
        val responseTurn = buildResponseTurn(seq = seq, response = response, fallbackIntent = "fake_audio_turn")
        recordAudioBytesSent(responseTurn.audioBytes)
        return responseTurn.frames
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

    private suspend fun setOutboundItems(channel: Channel<OutboundItem>) {
        lock.withLock {
            outboundItems = channel
        }
    }

    private suspend fun clearOutboundItems(channel: Channel<OutboundItem>) {
        lock.withLock {
            if (outboundItems === channel) {
                outboundItems = null
            }
        }
    }

    private suspend fun recordSubmittedTextTurn(turn: OutboundTurn) {
        lock.withLock {
            snapshot = snapshot.copy(
                lastMessageType = "app_text_turn",
                lastError = "",
                audioBytesSent = snapshot.audioBytesSent + turn.audioBytes,
                textTurnsSubmitted = snapshot.textTurnsSubmitted + 1,
                lastTextTurn = turn.text,
            )
        }
    }

    private suspend fun recordSubmittedControlMessage(message: BridgeMessage) {
        lock.withLock {
            snapshot = snapshot.copy(
                lastMessageType = message.type,
                lastError = "",
                messagesReceived = snapshot.messagesReceived + 1,
            )
        }
    }

    private suspend fun recordError(message: String) {
        lock.withLock {
            snapshot = snapshot.copy(lastError = message)
        }
    }

    private suspend fun robotHelloMissing(): Boolean =
        lock.withLock { !snapshot.robotHelloReceived }

    private suspend fun robotHelloRequiredError(seq: Int? = null): List<OutboundFrame> {
        recordError("robot hello is required before protected bridge writes")
        return textFrame(
            BridgeError(
                seq = seq,
                code = "robot_hello_required",
                detail = "Stack-chan must complete the bridge hello before audio, settings writes, or app text turns are accepted.",
                recoverable = true,
            ),
        )
    }

    private fun textFrame(message: BridgeMessage): List<OutboundFrame> =
        listOf(OutboundFrame.Text(encodeControlMessage(message)))

    private fun textFrames(vararg messages: BridgeMessage): List<OutboundFrame> =
        messages.map { OutboundFrame.Text(encodeControlMessage(it)) }

    private fun buildResponseTurn(seq: Int, response: BrainTurnResponse, fallbackIntent: String): OutboundTurn {
        val responseText = response.text.ifBlank { "I heard you." }
        val responseIntent = response.intent.ifBlank { fallbackIntent }
        val pcm = response.audioPcm16 ?: fakePcm16(responseText)
        val chunkSize = 512
        val chunks = pcm.asIterable().chunked(chunkSize).map { it.toByteArray() }
        val frames = buildList {
            addAll(
                textFrames(
                    Thinking(seq = seq),
                    ResponseStart(
                        seq = seq,
                        intent = responseIntent,
                        text = responseText,
                        arousal = response.arousal,
                        valence = response.valence,
                    ),
                    AudioStreamStart(
                        seq = seq,
                        format = "pcm16",
                        sampleRate = response.audioSampleRate,
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
        return OutboundTurn(seq = seq, text = responseText, audioBytes = pcm.size, frames = frames)
    }

    private suspend fun io.ktor.server.websocket.DefaultWebSocketServerSession.sendOutboundFrame(response: OutboundFrame) {
        when (response) {
            is OutboundFrame.Text -> outgoing.send(Frame.Text(response.value))
            is OutboundFrame.Binary -> outgoing.send(Frame.Binary(true, response.value))
        }
    }

    private fun fakePcm16(seed: String): ByteArray {
        val bytes = seed.encodeToByteArray()
        return ByteArray(1024) { index ->
            (bytes[index % bytes.size].toInt() + index).toByte()
        }
    }
}
