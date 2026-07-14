import org.jetbrains.compose.desktop.application.dsl.TargetFormat
import org.gradle.api.GradleException
import java.util.concurrent.TimeUnit

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.compose.multiplatform)
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    implementation(project(":core"))
    implementation(project(":ui"))
    implementation(compose.desktop.currentOs)
    implementation(libs.jmdns)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.ktor.client.cio)
    implementation(libs.ktor.client.core)
    implementation(libs.ktor.client.websockets)
    implementation(libs.ktor.server.cio)
    implementation(libs.ktor.server.core)
    implementation(libs.ktor.server.websockets)
    implementation(libs.kotlinx.serialization.json)
    testImplementation(libs.kotlin.test)
}

val desktopPythonRuntimeRoot = providers.gradleProperty("stackchan.desktop.pythonRuntimeRoot")
    .orElse(providers.environmentVariable("STACKCHAN_DESKTOP_PYTHON_RUNTIME_ROOT"))

val validateDesktopPythonRuntimePayload = tasks.register("validateDesktopPythonRuntimePayload") {
    group = "verification"
    description = "Validates the optional managed Python runtime payload before desktop packaging."

    inputs.property("runtimeRoot", desktopPythonRuntimeRoot.orNull ?: "")
    inputs.file(rootProject.layout.projectDirectory.file("../tools/check_desktop_python_runtime_payload.ps1"))

    doLast {
        val runtimeRoot = desktopPythonRuntimeRoot.orNull?.trim().orEmpty()
        if (runtimeRoot.isBlank()) {
            logger.lifecycle(
                "No managed Python runtime root configured; set -Pstackchan.desktop.pythonRuntimeRoot or " +
                "STACKCHAN_DESKTOP_PYTHON_RUNTIME_ROOT to package python-runtime/."
            )
            return@doLast
        }

        fun runCommand(command: List<String>): Pair<Int, String> {
            val process = ProcessBuilder(command)
                .redirectErrorStream(true)
                .start()
            val output = StringBuilder()
            val outputReader = Thread {
                process.inputStream.bufferedReader().use { reader ->
                    output.append(reader.readText())
                }
            }.apply {
                name = "desktop-runtime-validator-output"
                isDaemon = true
                start()
            }
            val finished = process.waitFor(120, TimeUnit.SECONDS)
            if (!finished) {
                process.destroyForcibly()
                outputReader.join(5_000)
                return 124 to "Command timed out: ${command.joinToString(" ")}"
            }
            outputReader.join(5_000)
            return process.exitValue() to output.toString()
        }

        val checker = rootProject.layout.projectDirectory
            .file("../tools/check_desktop_python_runtime_payload.ps1")
            .asFile
        val powerShell = listOf("pwsh", "powershell").firstOrNull { command ->
            runCatching {
                runCommand(listOf(command, "-NoProfile", "-Command", "\$PSVersionTable.PSVersion.ToString()")).first == 0
            }.getOrDefault(false)
        } ?: throw GradleException("Neither pwsh nor powershell was found; cannot validate desktop Python runtime payload.")

        val result = runCommand(
            listOf(
                powerShell,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                checker.absolutePath,
                "-RuntimeRoot",
                runtimeRoot,
                "-Json",
            )
        )
        if (result.first != 0) {
            throw GradleException(
                "Desktop Python runtime payload is not ready for packaging:\n${result.second.trim()}"
            )
        }
        logger.lifecycle("Desktop Python runtime payload validated: $runtimeRoot")
    }
}

val desktopNativeAppResourcesRoot = layout.buildDirectory.dir("generated/native-app-resources")
val prepareDesktopNativeAppResources = tasks.register<Sync>("prepareDesktopNativeAppResources") {
    group = "distribution"
    description = "Stages executable managed-runtime files beside the native desktop application."
    dependsOn(validateDesktopPythonRuntimePayload)
    into(desktopNativeAppResourcesRoot)

    desktopPythonRuntimeRoot.orNull?.trim()?.takeIf { it.isNotBlank() }?.let { runtimeRoot ->
        from(runtimeRoot) {
            into("common/python-runtime")
        }
    }
}

tasks.matching { it.name == "prepareAppResources" }.configureEach {
    dependsOn(prepareDesktopNativeAppResources)
}

tasks.processResources {
    dependsOn(validateDesktopPythonRuntimePayload)
    inputs.property("desktopPythonRuntimeRoot", desktopPythonRuntimeRoot.orNull ?: "")

    doFirst {
        destinationDir.resolve("python-runtime").deleteRecursively()
    }

    from(rootProject.layout.projectDirectory.dir("../bridge")) {
        include(
            "bridge_memory.py",
            "cancellable_process.py",
            "cancellation.py",
            "character_harness.py",
            "conversation_latency.py",
            "conversation_session.py",
            "lan_service.py",
            "local_facts.py",
            "local_runner.py",
            "persona_pack.py",
            "reference_bridge.py",
            "research_broker.py",
            "robot_embodiment.py",
            "stt_adapter.py",
            "tts_adapter.py",
            "utterance_text.py",
        )
        into("brain/bridge")
    }
    from(rootProject.layout.projectDirectory.dir("../personas")) {
        include("spark/**")
        include("glow/**")
        into("brain/personas")
    }
    from(rootProject.layout.projectDirectory.dir("../data")) {
        include("voice_source_provenance.yaml")
        into("brain/data")
    }
    from(rootProject.layout.projectDirectory.dir("../docs/media/voice")) {
        include("stackchan_spark_greeting.wav")
        include("stackchan_spark_thinking.wav")
        include("stackchan_spark_safety.wav")
        into("brain/docs/media/voice")
    }
}

compose.desktop {
    application {
        mainClass = "dev.stackchan.companion.desktop.MainKt"
        dependsOn("prepareDesktopNativeAppResources")

        nativeDistributions {
            targetFormats(TargetFormat.Dmg, TargetFormat.Msi, TargetFormat.Deb)
            packageName = "Stackchan Companion"
            packageVersion = "1.0.0"
            appResourcesRootDir.set(desktopNativeAppResourcesRoot)
        }
    }
}

tasks.register<JavaExec>("c0Spike") {
    group = "verification"
    description = "Runs the C0 desktop falsification spike and writes output/companion/c0-spike/SPIKE.md."
    classpath = sourceSets.main.get().runtimeClasspath
    mainClass.set("dev.stackchan.companion.desktop.C0SpikeKt")
    args(rootProject.layout.projectDirectory.dir("../output/companion/c0-spike").asFile.absolutePath)
}

tasks.register<JavaExec>("runtimeSmoke") {
    group = "verification"
    description = "Runs a desktop runtime WebSocket smoke test and writes output/companion/runtime-smoke/SMOKE.md."
    classpath = sourceSets.main.get().runtimeClasspath
    mainClass.set("dev.stackchan.companion.desktop.RuntimeSmokeKt")
    args(rootProject.layout.projectDirectory.dir("../output/companion/runtime-smoke").asFile.absolutePath)
}

tasks.register<JavaExec>("brainSupervisorSmoke") {
    group = "verification"
    description = "Starts the supervised Python brain, drives two text turns across restart, and writes C6 evidence."
    classpath = sourceSets.main.get().runtimeClasspath
    mainClass.set("dev.stackchan.companion.desktop.BrainSupervisorSmokeKt")
    args(rootProject.layout.projectDirectory.dir("../output/companion/c6-brain-supervisor").asFile.absolutePath)
}

tasks.register<JavaExec>("c6GuiRehearsalSmoke") {
    group = "verification"
    description = "Runs the desktop GUI C6 rehearsal flow and writes GUI_REHEARSAL evidence."
    classpath = sourceSets.main.get().runtimeClasspath
    mainClass.set("dev.stackchan.companion.desktop.BrainSupervisorRehearsalKt")
    args(rootProject.layout.projectDirectory.dir("../output/companion/c6-gui-rehearsal").asFile.absolutePath)
}
