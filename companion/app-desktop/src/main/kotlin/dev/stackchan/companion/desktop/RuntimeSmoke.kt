package dev.stackchan.companion.desktop

import dev.stackchan.companion.core.ClaimBrain
import dev.stackchan.companion.core.DEFAULT_BRIDGE_PORT
import dev.stackchan.companion.core.DeviceHello
import dev.stackchan.companion.core.DiagnosticsRequest
import dev.stackchan.companion.core.DiagnosticsSnapshot
import dev.stackchan.companion.core.EndpointHello
import dev.stackchan.companion.core.OwnerStatus
import dev.stackchan.companion.core.SettingsResult
import dev.stackchan.companion.core.SettingsSet
import dev.stackchan.companion.core.TrustedEndpoint
import dev.stackchan.companion.core.TrustedEndpointFileStore
import dev.stackchan.companion.core.TrustedEndpointRegistry
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
import java.time.Instant
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionStage
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

fun main(args: Array<String>) {
    val outDir = Path.of(args.firstOrNull() ?: "output/companion/runtime-smoke")
    Files.createDirectories(outDir)
    val report = runRuntimeSmoke(outDir)
    Files.writeString(outDir.resolve("SMOKE.md"), report.toMarkdown())
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
    val notes: List<String>,
) {
    val ok: Boolean =
        endpointHelloOk && settingsOk && ownerOk && diagnosticsOk

    fun toMarkdown(): String = buildString {
        appendLine("# Companion Runtime Smoke")
        appendLine()
        appendLine("- generated_at: `$generatedAt`")
        appendLine("- endpoint_hello_ok: `$endpointHelloOk`")
        appendLine("- settings_ok: `$settingsOk`")
        appendLine("- owner_ok: `$ownerOk`")
        appendLine("- diagnostics_ok: `$diagnosticsOk`")
        appendLine("- overall_ok: `$ok`")
        appendLine()
        appendLine("## Notes")
        notes.forEach { appendLine("- $it") }
    }
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

            return RuntimeSmokeReport(
                generatedAt = Instant.now(),
                endpointHelloOk = endpointHelloOk,
                settingsOk = settingsOk,
                ownerOk = ownerOk,
                diagnosticsOk = diagnosticsOk,
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
) : AutoCloseable {
    fun send(text: String) {
        socket.sendText(text, true).join()
    }

    fun nextText(): String =
        messages.poll(Duration.ofSeconds(5).toMillis(), TimeUnit.MILLISECONDS)
            ?: error("timed out waiting for websocket text")

    override fun close() {
        socket.sendClose(WebSocket.NORMAL_CLOSURE, "done").join()
    }

    companion object {
        fun connect(uri: String): RuntimeSmokeClient {
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
            return RuntimeSmokeClient(socket, messages)
        }
    }
}
