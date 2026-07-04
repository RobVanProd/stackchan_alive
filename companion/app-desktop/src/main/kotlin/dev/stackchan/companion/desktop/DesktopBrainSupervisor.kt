package dev.stackchan.companion.desktop

import java.nio.file.Files
import java.nio.file.Path
import java.time.Instant
import java.util.ArrayDeque
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

data class DesktopBrainSupervisorConfig(
    val pythonCommand: String = System.getProperty("stackchan.brain.python")
        ?: System.getenv("STACKCHAN_BRAIN_PYTHON")
        ?: defaultPythonCommand(),
    val scriptPath: Path = defaultRepoRoot().resolve("bridge").resolve("lan_service.py"),
    val host: String = System.getProperty("stackchan.brain.host") ?: "0.0.0.0",
    val port: Int = System.getProperty("stackchan.brain.port")?.toIntOrNull() ?: 8766,
    val runnerProfile: String = System.getProperty("stackchan.brain.runner_profile") ?: "gemma4-e2b-gguf",
    val arguments: List<String> = defaultLanServiceArguments(host, port, runnerProfile),
    val workingDirectory: Path? = scriptPath.parent,
    val maxLogLines: Int = 200,
)

data class DesktopBrainSupervisorSnapshot(
    val running: Boolean,
    val pid: Long?,
    val host: String,
    val port: Int,
    val command: List<String>,
    val scriptPath: Path,
    val startedAt: Instant?,
    val stoppedAt: Instant?,
    val exitCode: Int?,
    val recentLogs: List<String>,
)

class DesktopBrainSupervisor(
    private val config: DesktopBrainSupervisorConfig = DesktopBrainSupervisorConfig(),
) : AutoCloseable {
    private val lock = Any()
    private val logs = ArrayDeque<String>()
    private var process: Process? = null
    private var logThread: Thread? = null
    private var startedAt: Instant? = null
    private var stoppedAt: Instant? = null
    private var lastExitCode: Int? = null

    fun start(): DesktopBrainSupervisor {
        synchronized(lock) {
            check(process?.isAlive != true) { "desktop brain supervisor already started" }
            require(config.pythonCommand.isNotBlank()) { "python command is required" }
            require(Files.isRegularFile(config.scriptPath)) { "brain script does not exist: ${config.scriptPath}" }
            require(config.maxLogLines > 0) { "maxLogLines must be positive" }

            trimLogsLocked(clear = true)
            val command = commandLine()
            val builder = ProcessBuilder(command)
                .redirectErrorStream(true)
            config.workingDirectory?.let { builder.directory(it.toFile()) }
            appendLogLocked("> ${command.joinToString(" ")}")
            val started = try {
                builder.start()
            } catch (error: Exception) {
                stoppedAt = Instant.now()
                appendLogLocked("> brain service failed ${error.javaClass.simpleName}: ${error.message.orEmpty()}")
                throw error
            }
            process = started
            startedAt = Instant.now()
            stoppedAt = null
            lastExitCode = null
            logThread = thread(
                start = true,
                isDaemon = true,
                name = "stackchan-brain-supervisor-log",
            ) {
                started.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line -> appendLog(line) }
                }
            }
        }
        return this
    }

    fun stop(timeoutMs: Long = 2_000): DesktopBrainSupervisor {
        val runningProcess = synchronized(lock) { process } ?: return this
        if (runningProcess.isAlive) {
            runningProcess.destroy()
            if (!runningProcess.waitFor(timeoutMs, TimeUnit.MILLISECONDS)) {
                runningProcess.destroyForcibly()
                runningProcess.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            }
        }
        synchronized(lock) {
            lastExitCode = exitCodeOf(runningProcess)
            stoppedAt = Instant.now()
            appendLogLocked("> brain service stopped exit_code=${lastExitCode ?: "unknown"}")
            process = null
            logThread = null
        }
        return this
    }

    fun restart(): DesktopBrainSupervisor {
        stop()
        return start()
    }

    fun snapshot(): DesktopBrainSupervisorSnapshot =
        synchronized(lock) {
            val current = process
            val running = current?.isAlive == true
            val exitCode = if (running) null else current?.let(::exitCodeOf) ?: lastExitCode
            DesktopBrainSupervisorSnapshot(
                running = running,
                pid = current?.pid()?.takeIf { running },
                host = config.host,
                port = config.port,
                command = commandLine(),
                scriptPath = config.scriptPath,
                startedAt = startedAt,
                stoppedAt = stoppedAt,
                exitCode = exitCode,
                recentLogs = logs.toList(),
            )
        }

    override fun close() {
        stop()
    }

    private fun commandLine(): List<String> =
        listOf(config.pythonCommand, config.scriptPath.toAbsolutePath().normalize().toString()) + config.arguments

    private fun appendLog(line: String) {
        synchronized(lock) {
            appendLogLocked(line)
        }
    }

    private fun appendLogLocked(line: String) {
        logs.addLast(line)
        trimLogsLocked(clear = false)
    }

    private fun trimLogsLocked(clear: Boolean) {
        if (clear) {
            logs.clear()
            return
        }
        while (logs.size > config.maxLogLines) {
            logs.removeFirst()
        }
    }
}

private fun exitCodeOf(process: Process): Int? =
    runCatching { process.exitValue() }.getOrNull()

private fun defaultLanServiceArguments(
    host: String,
    port: Int,
    runnerProfile: String,
): List<String> =
    listOf(
        "--host",
        host,
        "--port",
        port.toString(),
        "--runner-profile",
        runnerProfile,
    )

private fun defaultPythonCommand(): String {
    val osName = System.getProperty("os.name").lowercase()
    return if ("win" in osName) "python" else "python3"
}

private fun defaultRepoRoot(): Path =
    Path.of(System.getProperty("stackchan.repo.root") ?: "..").toAbsolutePath().normalize()
