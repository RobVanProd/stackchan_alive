package dev.stackchan.companion.desktop

import java.nio.file.Files
import java.nio.file.Path
import java.time.Instant
import java.util.ArrayDeque
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

data class DesktopBrainSupervisorConfig(
    val pythonCommand: String = resolveDesktopBrainPythonCommand(),
    val scriptPath: Path = defaultRepoRoot().resolve("bridge").resolve("lan_service.py"),
    val host: String = System.getProperty("stackchan.brain.host") ?: "0.0.0.0",
    val port: Int = System.getProperty("stackchan.brain.port")?.toIntOrNull() ?: 8766,
    val runnerProfile: String = System.getProperty("stackchan.brain.runner_profile") ?: "gemma4-e2b-gguf",
    val arguments: List<String> = defaultLanServiceArguments(host, port, runnerProfile),
    val workingDirectory: Path? = scriptPath.parent,
    val maxLogLines: Int = 200,
)

data class DesktopPythonRuntimeStatus(
    val command: String,
    val available: Boolean,
    val version: String,
    val scriptAvailable: Boolean,
    val workingDirectory: Path?,
    val detail: String,
    val searchedCommands: List<String>,
)

data class DesktopBrainSupervisorSnapshot(
    val running: Boolean,
    val pid: Long?,
    val host: String,
    val port: Int,
    val command: List<String>,
    val scriptPath: Path,
    val pythonRuntime: DesktopPythonRuntimeStatus,
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
    private var pythonRuntimeStatus: DesktopPythonRuntimeStatus =
        inspectDesktopPythonRuntime(config.pythonCommand, config.scriptPath, config.workingDirectory)

    fun start(): DesktopBrainSupervisor {
        synchronized(lock) {
            check(process?.isAlive != true) { "desktop brain supervisor already started" }
            pythonRuntimeStatus = inspectDesktopPythonRuntime(
                config.pythonCommand,
                config.scriptPath,
                config.workingDirectory,
            )
            require(pythonRuntimeStatus.available) { pythonRuntimeStatus.detail }
            require(pythonRuntimeStatus.scriptAvailable) { pythonRuntimeStatus.detail }
            require(config.maxLogLines > 0) { "maxLogLines must be positive" }

            trimLogsLocked(clear = true)
            val command = commandLine()
            val builder = ProcessBuilder(command)
                .redirectErrorStream(true)
            config.workingDirectory?.let { builder.directory(it.toFile()) }
            appendLogLocked("> ${pythonRuntimeStatus.detail}")
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
                pythonRuntime = pythonRuntimeStatus,
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

internal fun resolveDesktopBrainPythonCommand(): String =
    desktopBrainPythonCandidates().firstOrNull { candidate ->
        inspectDesktopPythonRuntime(
            pythonCommand = candidate,
            scriptPath = defaultRepoRoot().resolve("bridge").resolve("lan_service.py"),
            workingDirectory = null,
        ).available
    } ?: defaultPythonCommand()

internal fun desktopBrainPythonCandidates(): List<String> =
    listOfNotNull(
        System.getProperty("stackchan.brain.python"),
        System.getProperty("stackchan.test.python"),
        System.getenv("STACKCHAN_BRAIN_PYTHON"),
        System.getenv("PYTHON"),
        System.getenv("PYTHON_EXE"),
        localWindowsPython(),
        "python",
        "python3",
    ).map { it.trim() }
        .filter { it.isNotBlank() }
        .distinct()

internal fun inspectDesktopPythonRuntime(
    pythonCommand: String,
    scriptPath: Path,
    workingDirectory: Path?,
    searchedCommands: List<String> = desktopBrainPythonCandidates(),
): DesktopPythonRuntimeStatus {
    val command = pythonCommand.trim()
    val scriptAvailable = Files.isRegularFile(scriptPath)
    if (command.isBlank()) {
        return DesktopPythonRuntimeStatus(
            command = command,
            available = false,
            version = "",
            scriptAvailable = scriptAvailable,
            workingDirectory = workingDirectory,
            detail = "Python command is not configured. Install Python 3.10+ or set STACKCHAN_BRAIN_PYTHON.",
            searchedCommands = searchedCommands,
        )
    }

    val probe = probePythonVersion(command)
    val versionText = probe.output.ifBlank { probe.error }
    val minimumOk = probe.exitCode == 0 && meetsMinimumPythonVersion(versionText)
    val available = minimumOk
    val detail = when {
        !probe.launched ->
            "Python runtime unavailable for `$command`: ${probe.error.ifBlank { "command could not start" }}. " +
                "Install Python 3.10+ or set STACKCHAN_BRAIN_PYTHON."
        probe.timedOut ->
            "Python runtime probe timed out for `$command`. Install Python 3.10+ or set STACKCHAN_BRAIN_PYTHON."
        !minimumOk ->
            "Python runtime `$command` reported `${versionText.ifBlank { "unknown version" }}`; " +
                "Stack-chan PC Brain Mode requires Python 3.10+."
        !scriptAvailable ->
            "Python runtime `$command` ${versionText.ifBlank { "detected" }} is ready, but brain script is missing: " +
                scriptPath.toAbsolutePath().normalize()
        else ->
            "Python runtime `$command` ${versionText.ifBlank { "detected" }} ready; brain script found."
    }

    return DesktopPythonRuntimeStatus(
        command = command,
        available = available,
        version = if (probe.exitCode == 0) versionText else "",
        scriptAvailable = scriptAvailable,
        workingDirectory = workingDirectory,
        detail = detail,
        searchedCommands = searchedCommands,
    )
}

private data class PythonProbe(
    val launched: Boolean,
    val timedOut: Boolean,
    val exitCode: Int?,
    val output: String,
    val error: String,
)

private fun probePythonVersion(command: String): PythonProbe =
    runCatching {
        val process = ProcessBuilder(command, "--version")
            .redirectErrorStream(true)
            .start()
        val finished = process.waitFor(5, TimeUnit.SECONDS)
        if (!finished) {
            process.destroyForcibly()
            return PythonProbe(
                launched = true,
                timedOut = true,
                exitCode = null,
                output = "",
                error = "",
            )
        }
        PythonProbe(
            launched = true,
            timedOut = false,
            exitCode = process.exitValue(),
            output = process.inputStream.bufferedReader().readText().trim(),
            error = "",
        )
    }.getOrElse { error ->
        PythonProbe(
            launched = false,
            timedOut = false,
            exitCode = null,
            output = "",
            error = error.message.orEmpty(),
        )
    }

private fun meetsMinimumPythonVersion(versionText: String): Boolean {
    val match = Regex("""Python\s+(\d+)\.(\d+)""").find(versionText) ?: return false
    val major = match.groupValues[1].toIntOrNull() ?: return false
    val minor = match.groupValues[2].toIntOrNull() ?: return false
    return major > 3 || (major == 3 && minor >= 10)
}

private fun defaultPythonCommand(): String {
    val osName = System.getProperty("os.name").lowercase()
    return if ("win" in osName) "python" else "python3"
}

private fun localWindowsPython(): String? {
    val localAppData = System.getenv("LOCALAPPDATA") ?: return null
    return Path.of(localAppData, "Programs", "Python", "Python312", "python.exe").toString()
}

internal fun defaultRepoRoot(): Path {
    System.getProperty("stackchan.repo.root")
        ?.takeIf { it.isNotBlank() }
        ?.let { return Path.of(it).toAbsolutePath().normalize() }

    val current = Path.of("").toAbsolutePath().normalize()
    return generateSequence(current) { it.parent }
        .firstOrNull { Files.isRegularFile(it.resolve("bridge").resolve("lan_service.py")) }
        ?: current.parent?.toAbsolutePath()?.normalize()
        ?: current
}
