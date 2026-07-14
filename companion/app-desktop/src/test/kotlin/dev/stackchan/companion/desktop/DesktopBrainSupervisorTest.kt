package dev.stackchan.companion.desktop

import java.nio.file.Files
import java.nio.file.Path
import java.time.Duration
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class DesktopBrainSupervisorTest {
    @Test
    fun supervisorStartsCapturesLogsAndStops() {
        val script = writeLoopScript("brain-supervisor-start")
        val config = testConfig(script, maxLogLines = 8)

        DesktopBrainSupervisor(config).use { supervisor ->
            supervisor.start()
            waitFor("boot log") {
                supervisor.snapshot().recentLogs.any { "brain boot" in it }
            }

            val running = supervisor.snapshot()
            assertEquals(true, running.running)
            assertNotNull(running.pid)
            assertTrue(running.command.first().contains("python", ignoreCase = true))
            assertTrue(running.recentLogs.any { "brain boot" in it })

            supervisor.stop()
            val stopped = supervisor.snapshot()
            assertEquals(false, stopped.running)
            assertNotNull(stopped.exitCode)
            assertTrue(stopped.recentLogs.any { "brain service stopped" in it })
        }
    }

    @Test
    fun supervisorRestartReplacesRunningProcess() {
        val script = writeLoopScript("brain-supervisor-restart")
        val config = testConfig(script)

        DesktopBrainSupervisor(config).use { supervisor ->
            supervisor.start()
            waitFor("first process") { supervisor.snapshot().pid != null }
            val firstPid = supervisor.snapshot().pid

            supervisor.restart()
            waitFor("second process") {
                val snapshot = supervisor.snapshot()
                snapshot.pid != null &&
                    snapshot.pid != firstPid &&
                    snapshot.recentLogs.any { "brain boot" in it }
            }

            val restarted = supervisor.snapshot()
            assertEquals(true, restarted.running)
            assertNotEquals(firstPid, restarted.pid)
            assertTrue(restarted.recentLogs.any { "brain boot" in it })
        }
    }

    @Test
    fun supervisorRejectsDoubleStart() {
        val script = writeLoopScript("brain-supervisor-double-start")
        val config = testConfig(script)

        DesktopBrainSupervisor(config).use { supervisor ->
            supervisor.start()

            assertFailsWith<IllegalStateException> {
                supervisor.start()
            }
        }
    }

    @Test
    fun supervisorRequiresExistingScript() {
        val missingScript = Files.createTempDirectory("stackchan-missing-brain").resolve("missing.py")
        val supervisor = DesktopBrainSupervisor(testConfig(missingScript))

        assertFailsWith<IllegalArgumentException> {
            supervisor.start()
        }
    }

    @Test
    fun supervisorReportsUnavailablePythonRuntimeBeforeStart() {
        val script = writeLoopScript("brain-supervisor-missing-python")
        val config = testConfig(script).copy(
            pythonCommand = "stackchan-python-command-that-does-not-exist",
        )
        val supervisor = DesktopBrainSupervisor(config)

        val snapshot = supervisor.snapshot()

        assertEquals(false, snapshot.pythonRuntime.available)
        assertEquals(true, snapshot.pythonRuntime.scriptAvailable)
        assertTrue(snapshot.pythonRuntime.detail.contains("Python runtime unavailable"))
        assertFailsWith<IllegalArgumentException> {
            supervisor.start()
        }
    }

    @Test
    fun packagedBrainScriptExtractsLanServiceResource() {
        val cacheRoot = Files.createTempDirectory("stackchan-packaged-brain")
        val script = packagedDesktopBrainScriptPath(cacheRoot)

        assertNotNull(script)
        assertTrue(Files.isRegularFile(script))
        assertTrue(Files.readString(script).contains("--runner-profile"))
        assertTrue(Files.isRegularFile(cacheRoot.resolve("bridge").resolve("bridge_memory.py")))
        assertTrue(Files.isRegularFile(cacheRoot.resolve("bridge").resolve("cancellable_process.py")))
        assertTrue(Files.isRegularFile(cacheRoot.resolve("bridge").resolve("cancellation.py")))
        assertTrue(Files.isRegularFile(cacheRoot.resolve("bridge").resolve("conversation_latency.py")))
        assertTrue(Files.isRegularFile(cacheRoot.resolve("bridge").resolve("conversation_session.py")))
        assertTrue(Files.isRegularFile(cacheRoot.resolve("bridge").resolve("local_facts.py")))
        assertTrue(Files.isRegularFile(cacheRoot.resolve("bridge").resolve("reference_bridge.py")))
        assertTrue(Files.isRegularFile(cacheRoot.resolve("bridge").resolve("research_broker.py")))
        assertTrue(Files.isRegularFile(cacheRoot.resolve("bridge").resolve("robot_embodiment.py")))
        assertTrue(Files.isRegularFile(cacheRoot.resolve("bridge").resolve("utterance_text.py")))
        assertTrue(Files.isRegularFile(cacheRoot.resolve("personas").resolve("spark").resolve("pack.yaml")))
        assertTrue(Files.isRegularFile(cacheRoot.resolve("data").resolve("voice_source_provenance.yaml")))

        val help = ProcessBuilder(pythonCommand(), script.toString(), "--help")
            .directory(script.parent.toFile())
            .redirectErrorStream(true)
            .start()
        assertTrue(help.waitFor(5, java.util.concurrent.TimeUnit.SECONDS))
        assertEquals(0, help.exitValue(), help.inputStream.bufferedReader().readText())
    }

    @Test
    fun managedPythonCandidatesIncludeOverrideAndPackagedRuntimeFolders() {
        val appHome = Files.createTempDirectory("stackchan-desktop-app-home")
        val runtimeOverride = Files.createTempDirectory("stackchan-python-runtime")
        val candidates = desktopBrainManagedPythonCandidates(
            appHome = appHome,
            runtimeOverride = runtimeOverride.toString(),
        )

        assertEquals(
            desktopBrainManagedPythonBinaryCandidates(runtimeOverride).first().toString(),
            candidates.first(),
        )
        assertTrue(
            appHome.resolve("python-runtime").resolve("bin").resolve("python3")
                .toAbsolutePath()
                .normalize()
                .toString() in candidates,
        )
    }

    @Test
    fun managedPythonRuntimeStatusReportsMissingPayload() {
        val appHome = Files.createTempDirectory("stackchan-desktop-app-home")
        val status = inspectDesktopManagedPythonRuntime(
            appHome = appHome,
            runtimeOverride = "",
        )

        assertEquals(false, status.present)
        assertEquals(null, status.root)
        assertTrue(status.detail.contains("No managed Python runtime payload"))
    }

    @Test
    fun managedPythonRuntimeStatusRequiresManifestAndPythonBinary() {
        val runtimeRoot = Files.createTempDirectory("stackchan-python-runtime")
        val manifestOnly = inspectDesktopManagedPythonRuntime(
            appHome = Files.createTempDirectory("stackchan-desktop-app-home"),
            runtimeOverride = runtimeRoot.toString(),
        )
        assertEquals(false, manifestOnly.present)

        Files.writeString(
            runtimeRoot.resolve("stackchan-python-runtime.json"),
            """
            {
              "schema": "stackchan.desktop-python-runtime.v1",
              "pythonVersion": "3.12.x",
              "source": "test-fixture"
            }
            """.trimIndent(),
        )
        val missingBinary = inspectDesktopManagedPythonRuntime(
            appHome = Files.createTempDirectory("stackchan-desktop-app-home"),
            runtimeOverride = runtimeRoot.toString(),
        )
        assertEquals(false, missingBinary.present)
        assertTrue(missingBinary.detail.contains("no platform Python executable"))

        val pythonPath = desktopBrainManagedPythonBinaryCandidates(runtimeRoot).first()
        Files.createDirectories(pythonPath.parent)
        Files.writeString(pythonPath, "# test python launcher placeholder\n")
        val present = inspectDesktopManagedPythonRuntime(
            appHome = Files.createTempDirectory("stackchan-desktop-app-home"),
            runtimeOverride = runtimeRoot.toString(),
        )

        assertEquals(true, present.present)
        assertEquals(runtimeRoot.toAbsolutePath().normalize(), present.root)
        assertEquals(runtimeRoot.resolve("stackchan-python-runtime.json"), present.manifestPath)
        assertEquals(pythonPath, present.pythonPath)
        assertTrue(present.detail.contains("Managed Python runtime payload present"))
    }

    @Test
    fun managedPythonRuntimeExecutableBitIsRestoredOnUnix() {
        if (System.getProperty("os.name").lowercase().contains("win")) return
        val runtimeRoot = Files.createTempDirectory("stackchan-python-runtime")
        try {
            val pythonPath = runtimeRoot.resolve("bin").resolve("python3")
            Files.createDirectories(pythonPath.parent)
            Files.writeString(pythonPath, "#!/usr/bin/env python3\n")
            pythonPath.toFile().setExecutable(false, false)

            assertFalse(pythonPath.toFile().canExecute())
            assertTrue(ensureDesktopRuntimeExecutable(pythonPath))
            assertTrue(pythonPath.toFile().canExecute())
        } finally {
            runtimeRoot.toFile().deleteRecursively()
        }
    }

    private fun testConfig(script: Path, maxLogLines: Int = 20): DesktopBrainSupervisorConfig =
        DesktopBrainSupervisorConfig(
            pythonCommand = pythonCommand(),
            scriptPath = script,
            arguments = emptyList(),
            workingDirectory = script.parent,
            maxLogLines = maxLogLines,
        )

    private fun writeLoopScript(prefix: String): Path {
        val directory = Files.createTempDirectory(prefix)
        val script = directory.resolve("fake_brain.py")
        Files.writeString(
            script,
            """
            import sys
            import time

            print("brain boot", flush=True)
            while True:
                print("brain tick", flush=True)
                time.sleep(0.05)
            """.trimIndent(),
        )
        return script
    }

    private fun waitFor(label: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + Duration.ofSeconds(5).toNanos()
        while (System.nanoTime() < deadline) {
            if (condition()) {
                return
            }
            Thread.sleep(25)
        }
        error("timed out waiting for $label")
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
        ).firstOrNull(::canRunPython) ?: error("Python is required for DesktopBrainSupervisorTest")

    private fun localWindowsPython(): String? {
        val localAppData = System.getenv("LOCALAPPDATA") ?: return null
        return Path.of(localAppData, "Programs", "Python", "Python312", "python.exe").toString()
    }

    private fun canRunPython(command: String): Boolean =
        runCatching {
            val process = ProcessBuilder(command, "--version")
                .redirectErrorStream(true)
                .start()
            process.waitFor(5, java.util.concurrent.TimeUnit.SECONDS) && process.exitValue() == 0
        }.getOrDefault(false)
}
