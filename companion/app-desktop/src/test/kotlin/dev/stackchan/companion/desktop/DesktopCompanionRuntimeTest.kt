package dev.stackchan.companion.desktop

import dev.stackchan.companion.core.DeviceHello
import dev.stackchan.companion.core.EndpointHello
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
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.Json

class DesktopCompanionRuntimeTest {
    @Test
    fun runtimeStartsEndpointServerAndPersistsSettings() {
        val storageDir = Files.createTempDirectory("stackchan-desktop-runtime")
        val firstConfig = runtimeConfig(storageDir)

        DesktopCompanionRuntime(firstConfig).use { runtime ->
            runtime.start()
            assertEquals(false, runtime.snapshot().mdnsAdvertised)
            val client = TestWebSocketClient.connect("ws://127.0.0.1:${firstConfig.port}/bridge")
            client.sendRobotHello()
            assertIs<EndpointHello>(decodeControlMessage(client.nextText()))

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

    @Test
    fun runtimeProjectsConnectedRobotIntoUiState() = runBlocking {
        val config = runtimeConfig(Files.createTempDirectory("stackchan-desktop-ui-state"))

        DesktopCompanionRuntime(config).use { runtime ->
            runtime.start()
            val before = runtime.toCompanionUiState()
            val client = TestWebSocketClient.connect("ws://127.0.0.1:${config.port}/bridge")

            client.send(
                encodeControlMessage(
                    DeviceHello(
                        deviceId = "stackchan-bench-01",
                        deviceName = "Stackchan Bench",
                        firmwareVersion = "bench-v1",
                        capabilities = listOf("settings", "diagnostics"),
                    ),
                ),
            )
            assertIs<EndpointHello>(decodeControlMessage(client.nextText()))
            val after = runtime.toCompanionUiState()

            assertEquals("Listening: 127.0.0.1:${config.port}", before.connection)
            assertEquals("Protocol", before.telemetry[0].label)
            assertEquals("stackchan.bridge.v1", before.telemetry[0].value)
            assertEquals("Audio", before.telemetry[1].label)
            assertEquals("fake", before.telemetry[1].value)
            assertEquals("Stopped", before.brainService.status)
            assertEquals("0.0.0.0:8766", before.brainService.endpoint)
            assertEquals("Heartbeat: listening", before.heartbeatStatus)
            assertEquals("Connected: Stackchan Bench", after.connection)
            assertEquals("hello", after.robotState)
            assertEquals("Heartbeat: connected", after.heartbeatStatus)
            assertEquals(true, after.endpoints.first().connected)
            assertEquals("Stackchan Bench", after.endpoints.first().name)
            assertEquals("bench-v1", after.endpoints.first().fingerprint)
            assertEquals("pc-runtime-test", after.endpoints[1].fingerprint)
            assertEquals("Firmware", after.telemetry[3].label)
            assertEquals("bench-v1", after.telemetry[3].value)
            assertEquals("fake; no live meter", after.audioStatus)
            client.close()
        }
    }

    @Test
    fun runtimeExportsDiagnosticsEvidenceJson() = runBlocking {
        val config = runtimeConfig(Files.createTempDirectory("stackchan-desktop-diagnostics-export"))

        DesktopCompanionRuntime(config).use { runtime ->
            runtime.start()

            val before = runtime.toCompanionUiState()
            val exported = Json.parseToJsonElement(runtime.exportDiagnosticsEvidenceJson()).jsonObject
            val brainService = exported["brain_service"]!!.jsonObject
            val diagnostics = exported["diagnostics"]!!.jsonObject
            val exportedPath = runtime.exportDiagnosticsEvidenceFile()
            val after = runtime.toCompanionUiState()

            assertEquals("stackchan.companion.diagnostics-export.v1", exported["schema"]!!.jsonPrimitive.content)
            assertEquals("pc-runtime-test", exported["runtime"]!!.jsonObject["endpoint_id"]!!.jsonPrimitive.content)
            assertEquals(false, exported["session"]!!.jsonObject["connected"]!!.jsonPrimitive.content.toBoolean())
            assertEquals(false, brainService["running"]!!.jsonPrimitive.content.toBoolean())
            assertEquals(config.brainSupervisorConfig.port, brainService["port"]!!.jsonPrimitive.content.toInt())
            assertTrue(brainService["command"]!!.jsonArray.isNotEmpty())
            assertEquals("stackchan.bridge.v1", diagnostics["bridge"]!!.jsonObject["protocol"]!!.jsonPrimitive.content)
            assertEquals("Ready", before.diagnosticsExport.status)
            assertEquals("Ready", before.c6Rehearsal.status)
            assertTrue(Files.isRegularFile(exportedPath))
            assertEquals(config.storageDir.resolve("diagnostics").resolve("DIAGNOSTICS_EXPORT.json"), exportedPath)
            assertEquals("Exported", after.diagnosticsExport.status)
            assertEquals(exportedPath.toString(), after.diagnosticsExport.path)
        }
    }

    @Test
    fun runtimeRunsC6GuiRehearsalAndPublishesEvidenceState() = runBlocking {
        val storageDir = Files.createTempDirectory("stackchan-desktop-c6-rehearsal")
        val scriptPath = defaultRepoRoot().resolve("bridge").resolve("lan_service.py")
        val brainPort = freePort()
        val config = runtimeConfig(storageDir).copy(
            brainSupervisorConfig = DesktopBrainSupervisorConfig(
                pythonCommand = pythonCommand(),
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
            ),
        )

        DesktopCompanionRuntime(config).use { runtime ->
            runtime.start()

            val result = runtime.runC6GuiRehearsal()
            val after = runtime.toCompanionUiState()

            assertEquals(true, result.report.ok)
            assertTrue(Files.isRegularFile(result.evidencePath))
            assertTrue(Files.isRegularFile(result.diagnosticsPath))
            assertEquals("Passed", after.c6Rehearsal.status)
            assertEquals(result.evidencePath.toString(), after.c6Rehearsal.path)
            assertEquals("Exported", after.diagnosticsExport.status)
            assertEquals(result.diagnosticsPath.toString(), after.diagnosticsExport.path)
        }
    }

    private fun pythonCommand(): String =
        listOfNotNull(
            System.getProperty("stackchan.test.python"),
            System.getenv("PYTHON"),
            System.getenv("PYTHON_EXE"),
            System.getenv("STACKCHAN_BRAIN_PYTHON"),
            localWindowsPython(),
            "python",
            "python3",
        ).firstOrNull(::canRunPython) ?: error("Python is required for C6 GUI rehearsal test")

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
}

private class TestWebSocketClient private constructor(
    private val socket: WebSocket,
    private val messages: LinkedBlockingQueue<String>,
) {
    fun send(text: String) {
        socket.sendText(text, true).join()
    }

    fun sendRobotHello() {
        send(
            encodeControlMessage(
                DeviceHello(
                    deviceId = "stackchan-bench-01",
                    deviceName = "Stackchan Bench",
                    firmwareVersion = "bench-v1",
                ),
            ),
        )
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
