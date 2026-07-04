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
)

class CompanionEndpointServer(
    private val config: EndpointServerConfig,
) : AutoCloseable {
    private val lock = Mutex()
    private var snapshot = EndpointSessionSnapshot()
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
                            if (frame !is Frame.Text) {
                                continue
                            }
                            val response = handleTextFrame(frame.readText())
                            if (response != null) {
                                outgoing.send(Frame.Text(response))
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

    private suspend fun handleTextFrame(text: String): String? {
        return try {
            when (val message = decodeControlMessage(text)) {
                is DeviceHello -> {
                    recordMessage(message)
                    encodeControlMessage(config.endpointHello)
                }
                is BridgeHello -> {
                    recordBridgeHello(message)
                    encodeControlMessage(config.endpointHello)
                }
                is Heartbeat -> {
                    recordMessageType(message.type)
                    null
                }
                else -> {
                    recordMessageType(message.type)
                    config.requestRouter.handle(message)?.let { encodeControlMessage(it) }
                }
            }
        } catch (error: RuntimeException) {
            recordError(error.message ?: error::class.simpleName.orEmpty())
            encodeControlMessage(
                BridgeError(
                    code = "bad_control_message",
                    detail = "Control message could not be decoded.",
                    recoverable = true,
                ),
            )
        }
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

    private suspend fun recordError(message: String) {
        lock.withLock {
            snapshot = snapshot.copy(lastError = message)
        }
    }
}
