import org.jetbrains.compose.desktop.application.dsl.TargetFormat

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

tasks.processResources {
    from(rootProject.layout.projectDirectory.dir("../bridge")) {
        include(
            "character_harness.py",
            "lan_service.py",
            "local_runner.py",
            "persona_pack.py",
            "reference_bridge.py",
            "stt_adapter.py",
            "tts_adapter.py",
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

        nativeDistributions {
            targetFormats(TargetFormat.Dmg, TargetFormat.Msi, TargetFormat.Deb)
            packageName = "Stackchan Companion"
            packageVersion = "1.0.0"
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
