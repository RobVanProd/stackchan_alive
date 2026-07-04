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
    testImplementation(libs.kotlin.test)
}

compose.desktop {
    application {
        mainClass = "dev.stackchan.companion.desktop.MainKt"

        nativeDistributions {
            targetFormats(TargetFormat.Dmg, TargetFormat.Msi, TargetFormat.Deb)
            packageName = "Stackchan Companion"
            packageVersion = "0.1.0"
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
