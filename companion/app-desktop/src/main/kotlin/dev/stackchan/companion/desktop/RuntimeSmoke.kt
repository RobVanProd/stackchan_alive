package dev.stackchan.companion.desktop

import dev.stackchan.companion.core.ClaimBrain
import dev.stackchan.companion.core.DEFAULT_BRIDGE_PORT
import dev.stackchan.companion.core.DeviceHello
import dev.stackchan.companion.core.DiagnosticsRequest
import dev.stackchan.companion.core.DiagnosticsSnapshot
import dev.stackchan.companion.core.EndpointHello
import dev.stackchan.companion.core.OwnerStatus
import dev.stackchan.companion.core.ResponseStart
import dev.stackchan.companion.core.SettingsResult
import dev.stackchan.companion.core.SettingsSet
import dev.stackchan.companion.core.AudioStreamEnd
import dev.stackchan.companion.core.AudioStreamStart
import dev.stackchan.companion.core.ResponseEnd
import dev.stackchan.companion.core.TrustedEndpoint
import dev.stackchan.companion.core.TrustedEndpointFileStore
import dev.stackchan.companion.core.TrustedEndpointRegistry
import dev.stackchan.companion.core.UtteranceAudio
import dev.stackchan.companion.core.UtteranceEnd
import dev.stackchan.companion.core.UtteranceStart
import dev.stackchan.companion.core.decodeControlMessage
import dev.stackchan.companion.core.encodeControlMessage
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.Path
import java.time.Duration
import java.time.Instant
import java.util.Base64
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionStage
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

fun main(args: Array<String>) {
    val outDir = Path.of(args.firstOrNull() ?: "output/companion/runtime-smoke")
    Files.createDirectories(outDir)
    val report = runRuntimeSmoke(outDir)
    Files.writeString(outDir.resolve("SMOKE.md"), report.toMarkdown())
    Files.writeString(outDir.resolve("SMOKE.json"), report.toJson())
    if (!report.ok) {
        error("Runtime smoke failed; see ${outDir.resolve("SMOKE.md")}")
    }
}

data class RuntimeSmokeReport(
    val generatedAt: Instant,
    val endpointHelloOk: Boolean,
    val settingsOk: Boolean,
    val ownerOk: Boolean,
    val diagnosticsOk: Boolean,
    val fakeAudioOk: Boolean,
    val notes: List<String>,
) {
    val ok: Boolean =
        endpointHelloOk && settingsOk && ownerOk && diagnosticsOk && fakeAudioOk

    fun toMarkdown(): String = buildString {
        appendLine("# Companion Runtime Smoke")
        appendLine()
        appendLine("- generated_at: `$generatedAt`")
        appendLine("- endpoint_hello_ok: `$endpointHelloOk`")
        appendLine("- settings_ok: `$settingsOk`")
        appendLine("- owner_ok: `$ownerOk`")
        appendLine("- diagnostics_ok: `$diagnosticsOk`")
        appendLine("- fake_audio_ok: `$fakeAudioOk`")
        appendLine("- overall_ok: `$ok`")
        appendLine()
        appendLine("## Notes")
        notes.forEach { appendLine("- $it") }
    }

    fun toJson(): String =
        buildJsonObject {
            put("schema", "stackchan.companion.runtime-smoke.v1")
            put("generated_at", generatedAt.toString())
            put("endpoint_hello_ok", endpointHelloOk)
            put("settings_ok", settingsOk)
            put("owner_ok", ownerOk)
            put("diagnostics_ok", diagnosticsOk)
            put("fake_audio_ok", fakeAudioOk)
            put("overall_ok", ok)
            put("notes", JsonArray(notes.map { JsonPrimitive(it) }))
        }.toString()
}

fun runRuntimeSmoke(outDir: Path): RuntimeSmokeReport {
    val notes = mutableListOf<String>()
    val stateDir = Files.createTempDirectory(outDir, "state-")
    notes += "Using isolated state directory `${stateDir.fileName}`."
    seedTrustedEndpoint(stateDir)
    val port = freeLoopbackPort()
    val config = DesktopCompanionRuntimeConfig(
        host = "127.0.0.1",
        port = port,
        storageDir = stateDir,
        endpointId = "pc-runtime-smoke",
        advertiseMdns = false,
    )

    DesktopCompanionRuntime(config).use { runtime ->
        runtime.start()
        RuntimeSmokeClient.connect("ws://127.0.0.1:$port/bridge").use { client ->
            val endpointHelloOk = runCatching {
                client.send(
                    encodeControlMessage(
                        DeviceHello(
                            deviceId = "stackchan-smoke-device",
                            firmwareVersion = "bench-smoke",
                            capabilities = listOf("settings", "diagnostics"),
                        ),
                    ),
                )
                val hello = decodeControlMessage(client.nextText()) as EndpointHello
                notes += "Endpoint hello returned `${hello.endpointId}` with ${hello.capabilities.joinToString(",")}."
                hello.endpointId == "pc-runtime-smoke" && "diagnostics" in hello.capabilities
            }.getOrElse {
                notes += "Endpoint hello failed: ${it.message}"
                false
            }

            val settingsOk = runCatching {
                client.send(
                    encodeControlMessage(
                        SettingsSet(
                            version = 1,
                            settings = buildJsonObject {
                                put("display", buildJsonObject {
                                    put("brightness", JsonPrimitive(61))
                                })
                            },
                        ),
                    ),
                )
                val result = decodeControlMessage(client.nextText()) as SettingsResult
                notes += "Settings set returned ok=${result.ok}, version=${result.version}."
                result.ok && result.version == 2
            }.getOrElse {
                notes += "Settings set failed: ${it.message}"
                false
            }

            val ownerOk = runCatching {
                client.send(
                    encodeControlMessage(
                        ClaimBrain(endpointId = "phone-runtime-smoke", reason = "smoke owner claim"),
                    ),
                )
                val owner = decodeControlMessage(client.nextText()) as OwnerStatus
                notes += "Owner claim returned `${owner.activeBrainOwner}` in state `${owner.state}`."
                owner.activeBrainOwner == "phone-runtime-smoke" && owner.state == "claimed"
            }.getOrElse {
                notes += "Owner claim failed: ${it.message}"
                false
            }

            val diagnosticsOk = runCatching {
                client.send(
                    encodeControlMessage(DiagnosticsRequest(domains = listOf("bridge", "audio", "model"))),
                )
                val diagnostics = decodeControlMessage(client.nextText()) as DiagnosticsSnapshot
                val protocol = diagnostics.bridge["protocol"]!!.jsonPrimitive.content
                val settingsVersion = diagnostics.bridge["settings_version"]!!.jsonPrimitive.content.toInt()
                val audioEngine = diagnostics.audio!!.jsonObject["engine"]!!.jsonPrimitive.content
                notes += "Diagnostics returned protocol `$protocol`, settings_version=$settingsVersion, audio=$audioEngine."
                protocol == "stackchan.bridge.v1" && settingsVersion == 2 && audioEngine == "fake"
            }.getOrElse {
                notes += "Diagnostics failed: ${it.message}"
                false
            }

            val fakeAudioOk = runCatching {
                client.send(encodeControlMessage(UtteranceStart(seq = 42, sampleRate = 16000)))
                client.sendBinary(ByteArray(320) { 3 })
                client.send(
                    encodeControlMessage(
                        UtteranceAudio(
                            seq = 42,
                            pcmB64 = Base64.getEncoder().encodeToString(ByteArray(160) { 4 }),
                        ),
                    ),
                )
                client.send(encodeControlMessage(UtteranceEnd(seq = 42, transcript = "runtime smoke audio")))
                val thinking = decodeControlMessage(client.nextText())
                val response = decodeControlMessage(client.nextText()) as ResponseStart
                val start = decodeControlMessage(client.nextText()) as AudioStreamStart
                val binaryBytes = (1..start.chunks).sumOf { client.nextBinary().size }
                val mouthFrame = decodeControlMessage(client.nextText())
                val finalMouthFrame = decodeControlMessage(client.nextText())
                val end = decodeControlMessage(client.nextText()) as AudioStreamEnd
                val responseEnd = decodeControlMessage(client.nextText()) as ResponseEnd
                notes += "Fake audio turn returned ${thinking.type}, intent=${response.intent}, chunks=${start.chunks}, binary_bytes=$binaryBytes."
                response.intent == "fake_audio_turn" &&
                    start.format == "pcm16" &&
                    start.audioBytes == binaryBytes &&
                    end.audioBytes == start.audioBytes &&
                    end.chunks == start.chunks &&
                    mouthFrame.type == "audio" &&
                    finalMouthFrame.type == "audio" &&
                    responseEnd.seq == 42
            }.getOrElse {
                notes += "Fake audio turn failed: ${it.message}"
                false
            }

            return RuntimeSmokeReport(
                generatedAt = Instant.now(),
                endpointHelloOk = endpointHelloOk,
                settingsOk = settingsOk,
                ownerOk = ownerOk,
                diagnosticsOk = diagnosticsOk,
                fakeAudioOk = fakeAudioOk,
                notes = notes,
            )
        }
    }
}

private fun seedTrustedEndpoint(stateDir: Path) {
    val registry = TrustedEndpointRegistry()
    registry.upsert(
        TrustedEndpoint(
            endpointId = "phone-runtime-smoke",
            endpointName = "Runtime Smoke Phone",
            endpointKind = "android",
            publicKeyFingerprint = "sha256:1111222233334444",
            priority = 80,
            autoConnect = true,
            capabilities = listOf("settings", "diagnostics", "brain_owner"),
        ),
    )
    TrustedEndpointFileStore(stateDir.resolve("trusted_endpoints.json")).save(registry)
}

private fun freeLoopbackPort(): Int =
    ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { socket ->
        socket.localPort.takeIf { it in 1..65535 } ?: DEFAULT_BRIDGE_PORT
    }

private class RuntimeSmokeClient private constructor(
    private val socket: WebSocket,
    private val messages: LinkedBlockingQueue<String>,
    private val binaryMessages: LinkedBlockingQueue<ByteArray>,
) : AutoCloseable {
    fun send(text: String) {
        socket.sendText(text, true).join()
    }

    fun sendBinary(bytes: ByteArray) {
        socket.sendBinary(ByteBuffer.wrap(bytes), true).join()
    }

    fun nextText(): String =
        messages.poll(Duration.ofSeconds(5).toMillis(), TimeUnit.MILLISECONDS)
            ?: error("timed out waiting for websocket text")

    fun nextBinary(): ByteArray =
        binaryMessages.poll(Duration.ofSeconds(5).toMillis(), TimeUnit.MILLISECONDS)
            ?: error("timed out waiting for websocket binary")

    override fun close() {
        socket.sendClose(WebSocket.NORMAL_CLOSURE, "done").join()
    }

    companion object {
        fun connect(uri: String): RuntimeSmokeClient {
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
                .get(Duration.ofSeconds(5).toMillis(), TimeUnit.MILLISECONDS)
            socket.request(1)
            return RuntimeSmokeClient(socket, messages, binaryMessages)
        }
    }
}
