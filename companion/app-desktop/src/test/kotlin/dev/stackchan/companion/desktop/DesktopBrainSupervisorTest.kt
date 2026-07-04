package dev.stackchan.companion.desktop

import java.nio.file.Files
import java.nio.file.Path
import java.time.Duration
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
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
