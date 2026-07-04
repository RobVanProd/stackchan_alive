package dev.stackchan.companion.desktop

import dev.stackchan.companion.core.BridgeHello
import dev.stackchan.companion.core.CompanionIdentity
import dev.stackchan.companion.core.DeviceHello
import dev.stackchan.companion.core.Listening
import dev.stackchan.companion.core.ResponseEnd
import dev.stackchan.companion.core.ResponseStart
import dev.stackchan.companion.core.Thinking
import dev.stackchan.companion.core.UtteranceEnd
import dev.stackchan.companion.core.UtteranceStart
import dev.stackchan.companion.core.decodeControlMessage
import dev.stackchan.companion.core.encodeControlMessage
import java.net.ConnectException
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
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionStage
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

fun main(args: Array<String>) {
    val outDir = Path.of(args.firstOrNull() ?: "output/companion/c6-brain-supervisor")
    Files.createDirectories(outDir)
    val report = runBrainSupervisorSmoke(outDir)
    Files.writeString(outDir.resolve("BRAIN_SUPERVISOR_SMOKE.md"), report.toMarkdown())
    Files.writeString(outDir.resolve("BRAIN_SUPERVISOR_SMOKE.json"), report.toJson())
    Files.writeString(outDir.resolve("DIAGNOSTICS_EXPORT.json"), report.diagnosticsExportJson)
    if (!report.ok) {
        error("Brain supervisor smoke failed; see ${outDir.resolve("BRAIN_SUPERVISOR_SMOKE.md")}")
    }
}

data class BrainSupervisorSmokeReport(
    val generatedAt: Instant,
    val pythonCommand: String,
    val scriptPath: Path,
    val runtimePort: Int,
    val brainPort: Int,
    val firstStart: DesktopBrainSupervisorSnapshot,
    val firstTurn: BrainTurnEvidence,
    val firstStop: DesktopBrainSupervisorSnapshot,
    val restartStart: DesktopBrainSupervisorSnapshot,
    val secondTurn: BrainTurnEvidence,
    val finalStop: DesktopBrainSupervisorSnapshot,
    val diagnosticsExportJson: String,
    val notes: List<String>,
) {
    val startOk: Boolean = firstStart.running && firstStart.pid != null
    val firstStopOk: Boolean = firstStop.running == false && firstStop.exitCode == 0
    val restartOk: Boolean = restartStart.running && restartStart.pid != null && restartStart.pid != firstStart.pid
    val finalStopOk: Boolean = finalStop.running == false && finalStop.exitCode == 0
    val diagnosticsExportOk: Boolean = diagnosticsExportJson.contains("stackchan.companion.diagnostics-export.v1") &&
        diagnosticsExportJson.contains("brain_service")
    val ok: Boolean =
        startOk && firstTurn.ok && firstStopOk && restartOk && secondTurn.ok && finalStopOk && diagnosticsExportOk

    fun toMarkdown(): String = buildString {
        appendLine("# Companion C6 Brain Supervisor Smoke")
        appendLine()
        appendLine("- generated_at: `$generatedAt`")
        appendLine("- python_command: `$pythonCommand`")
        appendLine("- script_path: `$scriptPath`")
        appendLine("- runtime_endpoint: `127.0.0.1:$runtimePort`")
        appendLine("- brain_endpoint: `127.0.0.1:$brainPort`")
        appendLine("- start_ok: `$startOk`")
        appendLine("- first_turn_ok: `${firstTurn.ok}`")
        appendLine("- first_stop_ok: `$firstStopOk`")
        appendLine("- restart_ok: `$restartOk`")
        appendLine("- second_turn_ok: `${secondTurn.ok}`")
        appendLine("- final_stop_ok: `$finalStopOk`")
        appendLine("- diagnostics_export_ok: `$diagnosticsExportOk`")
        appendLine("- overall_ok: `$ok`")
        appendLine()
        appendLine("## Turns")
        appendLine()
        appendLine("- first_frame_order: `${firstTurn.frameOrder.joinToString(" -> ")}`")
        appendLine("- first_response_text: `${firstTurn.responseText}`")
        appendLine("- first_response_end_latency_ms: `${firstTurn.responseEndLatencyMs}`")
        appendLine("- second_frame_order: `${secondTurn.frameOrder.joinToString(" -> ")}`")
        appendLine("- second_response_text: `${secondTurn.responseText}`")
        appendLine("- second_response_end_latency_ms: `${secondTurn.responseEndLatencyMs}`")
        appendLine()
        appendLine("## Supervisor")
        appendLine()
        appendLine("- first_pid: `${firstStart.pid}`")
        appendLine("- first_exit_code: `${firstStop.exitCode}`")
        appendLine("- restart_pid: `${restartStart.pid}`")
        appendLine("- final_exit_code: `${finalStop.exitCode}`")
        appendLine()
        appendLine("## Notes")
        notes.forEach { appendLine("- $it") }
    }

    fun toJson(): String =
        buildJsonObject {
            put("schema", "stackchan.companion.c6-brain-supervisor-smoke.v1")
            put("generated_at", generatedAt.toString())
            put("python_command", pythonCommand)
            put("script_path", scriptPath.toString())
            put("runtime_port", runtimePort)
            put("brain_port", brainPort)
            put("start_ok", startOk)
            put("first_turn_ok", firstTurn.ok)
            put("first_stop_ok", firstStopOk)
            put("restart_ok", restartOk)
            put("second_turn_ok", secondTurn.ok)
            put("final_stop_ok", finalStopOk)
            put("diagnostics_export_ok", diagnosticsExportOk)
            put("overall_ok", ok)
            put("first_start", firstStart.toJson())
            put("first_turn", firstTurn.toJson())
            put("first_stop", firstStop.toJson())
            put("restart_start", restartStart.toJson())
            put("second_turn", secondTurn.toJson())
            put("final_stop", finalStop.toJson())
            put("notes", JsonArray(notes.map { JsonPrimitive(it) }))
        }.toString()
}

data class BrainTurnEvidence(
    val ok: Boolean,
    val frameOrder: List<String>,
    val responseText: String,
    val thinkingLatencyMs: Long,
    val responseEndLatencyMs: Long,
)

private fun BrainTurnEvidence.toJson() =
    buildJsonObject {
        put("ok", ok)
        put("frame_order", JsonArray(frameOrder.map { JsonPrimitive(it) }))
        put("response_text", responseText)
        put("thinking_latency_ms", thinkingLatencyMs)
        put("response_end_latency_ms", responseEndLatencyMs)
    }

fun runBrainSupervisorSmoke(outDir: Path): BrainSupervisorSmokeReport = runBlocking {
    val notes = mutableListOf<String>()
    val repoRoot = defaultRepoRoot()
    val scriptPath = repoRoot.resolve("bridge").resolve("lan_service.py")
    val pythonCommand = resolvePythonCommand()
    val runtimePort = freeLoopbackPort()
    val brainPort = freeLoopbackPort()
    val stateDir = Files.createTempDirectory(outDir, "state-")
    notes += "Using isolated runtime state directory `${stateDir.fileName}`."
    notes += "Driving Python brain through DesktopCompanionRuntime start/stop/restart controls."

    val brainConfig = DesktopBrainSupervisorConfig(
        pythonCommand = pythonCommand,
        scriptPath = scriptPath,
        host = "127.0.0.1",
        port = brainPort,
        arguments = listOf(
            "--host",
            "127.0.0.1",
            "--port",
            brainPort.toString(),
            "--runner-profile",
            "gemma4-e2b-gguf",
            "--runner-case",
            "greeting",
            "--once",
        ),
        workingDirectory = scriptPath.parent,
    )
    val runtimeConfig = DesktopCompanionRuntimeConfig(
        host = "127.0.0.1",
        port = runtimePort,
        storageDir = stateDir,
        endpointId = "pc-c6-brain-smoke",
        advertiseMdns = false,
        brainSupervisorConfig = brainConfig,
    )

    DesktopCompanionRuntime(runtimeConfig).use { runtime ->
        runtime.start()
        val firstStart = runtime.startBrainService()
        val firstTurn = driveTextTurn(brainPort, deviceId = "stackchan-c6-smoke-1", seq = 71)
        waitForBrainExit(runtime)
        val firstStop = runtime.stopBrainService()

        val restartStart = runtime.restartBrainService()
        val secondTurn = driveTextTurn(brainPort, deviceId = "stackchan-c6-smoke-2", seq = 72)
        waitForBrainExit(runtime)
        val finalStop = runtime.stopBrainService()

        val diagnosticsExportJson = runtime.exportDiagnosticsEvidenceJson()
        notes += "First brain service pid `${firstStart.pid}` exited with code `${firstStop.exitCode}`."
        notes += "Restarted brain service pid `${restartStart.pid}` exited with code `${finalStop.exitCode}`."
        notes += "Diagnostics export written as `DIAGNOSTICS_EXPORT.json`."

        BrainSupervisorSmokeReport(
            generatedAt = Instant.now(),
            pythonCommand = pythonCommand,
            scriptPath = scriptPath,
            runtimePort = runtimePort,
            brainPort = brainPort,
            firstStart = firstStart,
            firstTurn = firstTurn,
            firstStop = firstStop,
            restartStart = restartStart,
            secondTurn = secondTurn,
            finalStop = finalStop,
            diagnosticsExportJson = diagnosticsExportJson,
            notes = notes,
        )
    }
}

private fun driveTextTurn(port: Int, deviceId: String, seq: Int): BrainTurnEvidence {
    BrainSmokeClient.connectWithRetry("ws://127.0.0.1:$port/bridge").use { client ->
        val startedAt = System.nanoTime()
        client.send(encodeControlMessage(DeviceHello(deviceId = deviceId, capabilities = listOf("diagnostics"))))
        val hello = decodeControlMessage(client.nextText()) as BridgeHello
        client.send(encodeControlMessage(UtteranceStart(seq = seq, sampleRate = 16000)))
        val listening = decodeControlMessage(client.nextText()) as Listening
        client.send(encodeControlMessage(UtteranceEnd(seq = seq, transcript = "Hello Stackchan.")))
        val thinking = decodeControlMessage(client.nextText()) as Thinking
        val thinkingLatencyMs = Duration.ofNanos(System.nanoTime() - startedAt).toMillis()
        val responseStart = decodeControlMessage(client.nextText()) as ResponseStart
        val frameOrder = mutableListOf(hello.type, listening.type, thinking.type, responseStart.type)
        var responseEndLatencyMs = thinkingLatencyMs
        while (true) {
            val next = decodeControlMessage(client.nextText())
            frameOrder += next.type
            if (next is ResponseEnd) {
                responseEndLatencyMs = Duration.ofNanos(System.nanoTime() - startedAt).toMillis()
                break
            }
        }
        val ok = hello.protocol == CompanionIdentity.protocol &&
            thinking.seq == seq &&
            responseStart.seq == seq &&
            responseStart.text.isNotBlank() &&
            frameOrder.first() == "hello" &&
            frameOrder.contains("thinking") &&
            frameOrder.contains("response_start") &&
            frameOrder.last() == "response_end"
        return BrainTurnEvidence(
            ok = ok,
            frameOrder = frameOrder,
            responseText = responseStart.text,
            thinkingLatencyMs = thinkingLatencyMs,
            responseEndLatencyMs = responseEndLatencyMs,
        )
    }
}

private fun waitForBrainExit(runtime: DesktopCompanionRuntime): DesktopBrainSupervisorSnapshot {
    val deadline = System.nanoTime() + Duration.ofSeconds(8).toNanos()
    while (System.nanoTime() < deadline) {
        val snapshot = runtime.snapshot().brainSupervisor
        if (!snapshot.running && snapshot.exitCode != null) {
            return snapshot
        }
        Thread.sleep(50)
    }
    return runtime.snapshot().brainSupervisor
}

private fun DesktopBrainSupervisorSnapshot.toJson() =
    buildJsonObject {
        put("running", running)
        pid?.let { put("pid", it) }
        put("host", host)
        put("port", port)
        put("script_path", scriptPath.toString())
        put("command", JsonArray(command.map { JsonPrimitive(it) }))
        startedAt?.let { put("started_at", it.toString()) }
        stoppedAt?.let { put("stopped_at", it.toString()) }
        exitCode?.let { put("exit_code", it) }
        put("recent_logs", JsonArray(recentLogs.map { JsonPrimitive(it) }))
    }

private fun resolvePythonCommand(): String =
    listOfNotNull(
        System.getProperty("stackchan.brain.python"),
        System.getenv("STACKCHAN_BRAIN_PYTHON"),
        System.getenv("PYTHON"),
        System.getenv("PYTHON_EXE"),
        localWindowsPython(),
        "python",
        "python3",
    ).firstOrNull(::canRunPython) ?: error("Python 3 is required for brain supervisor smoke")

private fun localWindowsPython(): String? {
    val localAppData = System.getenv("LOCALAPPDATA") ?: return null
    return Path.of(localAppData, "Programs", "Python", "Python312", "python.exe").toString()
}

private fun canRunPython(command: String): Boolean =
    runCatching {
        val process = ProcessBuilder(command, "--version")
            .redirectErrorStream(true)
            .start()
        process.waitFor(5, TimeUnit.SECONDS) && process.exitValue() == 0
    }.getOrDefault(false)

private fun freeLoopbackPort(): Int =
    ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { socket ->
        socket.localPort
    }

private class BrainSmokeClient private constructor(
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
        fun connectWithRetry(uri: String): BrainSmokeClient {
            val deadline = System.nanoTime() + Duration.ofSeconds(8).toNanos()
            var lastError: Throwable? = null
            while (System.nanoTime() < deadline) {
                try {
                    return connect(uri)
                } catch (error: Throwable) {
                    lastError = error
                    if (!isRetryableConnectError(error)) {
                        throw error
                    }
                    Thread.sleep(100)
                }
            }
            throw IllegalStateException("timed out connecting to $uri", lastError)
        }

        private fun connect(uri: String): BrainSmokeClient {
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

                override fun onBinary(
                    webSocket: WebSocket,
                    data: ByteBuffer,
                    last: Boolean,
                ): CompletionStage<*> {
                    webSocket.request(1)
                    return CompletableFuture.completedFuture(null)
                }
            }
            val socket = HttpClient
                .newHttpClient()
                .newWebSocketBuilder()
                .connectTimeout(Duration.ofSeconds(2))
                .buildAsync(URI.create(uri), listener)
                .get(Duration.ofSeconds(2).toMillis(), TimeUnit.MILLISECONDS)
            socket.request(1)
            return BrainSmokeClient(socket, messages)
        }

        private fun isRetryableConnectError(error: Throwable): Boolean {
            var current: Throwable? = error
            while (current != null) {
                if (current is ConnectException) {
                    return true
                }
                current = current.cause
            }
            return false
        }
    }
}
