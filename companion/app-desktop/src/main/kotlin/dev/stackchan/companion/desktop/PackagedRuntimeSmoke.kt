package dev.stackchan.companion.desktop

import dev.stackchan.companion.core.CompanionIdentity
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal data class PackagedRuntimeSmokeReport(
    val status: String,
    val platform: String,
    val appVersion: String,
    val protocol: String,
    val resourcesDirectory: Path,
    val runtimeRoot: Path?,
    val runtimeManifest: Path?,
    val runtimeExecutable: Path?,
    val runtimePresent: Boolean,
    val pythonAvailable: Boolean,
    val pythonVersion: String,
    val brainScript: Path,
    val brainScriptAvailable: Boolean,
    val issues: List<String>,
) {
    fun toJson(): String =
        Json { prettyPrint = true }.encodeToString(
            buildJsonObject {
                put("schema", "stackchan.desktop-packaged-runtime-smoke.v1")
                put("status", status)
                put("platform", platform)
                put("appVersion", appVersion)
                put("protocol", protocol)
                put("resourcesDirectory", resourcesDirectory.toString())
                put("runtimeRoot", runtimeRoot?.let { JsonPrimitive(it.toString()) } ?: JsonNull)
                put("runtimeManifest", runtimeManifest?.let { JsonPrimitive(it.toString()) } ?: JsonNull)
                put("runtimeExecutable", runtimeExecutable?.let { JsonPrimitive(it.toString()) } ?: JsonNull)
                put("runtimePresent", runtimePresent)
                put("pythonAvailable", pythonAvailable)
                put("pythonVersion", pythonVersion)
                put("brainScript", brainScript.toString())
                put("brainScriptAvailable", brainScriptAvailable)
                put("scope", "extracted-native-package-headless-runtime-probe")
                put("substitutesForTargetInstall", false)
                put("issues", JsonArray(issues.map(::JsonPrimitive)))
            },
        )
}

internal fun inspectPackagedRuntimeSmoke(
    appHome: Path = desktopApplicationHome(),
    brainScript: Path = defaultDesktopBrainScriptPath(),
): PackagedRuntimeSmokeReport {
    val normalizedAppHome = appHome.toAbsolutePath().normalize()
    val expectedRuntimeRoot = normalizedAppHome.resolve("python-runtime")
    val managed = inspectDesktopManagedPythonRuntime(appHome = normalizedAppHome)
    val python = managed.pythonPath?.let { pythonPath ->
        inspectDesktopPythonRuntime(
            pythonCommand = pythonPath.toString(),
            scriptPath = brainScript,
            workingDirectory = brainScript.parent,
            searchedCommands = listOf(pythonPath.toString()),
        )
    }
    return buildPackagedRuntimeSmokeReport(normalizedAppHome, brainScript, managed, python)
}

internal fun buildPackagedRuntimeSmokeReport(
    appHome: Path,
    brainScript: Path,
    managed: DesktopManagedPythonRuntimeStatus,
    python: DesktopPythonRuntimeStatus?,
): PackagedRuntimeSmokeReport {
    val normalizedAppHome = appHome.toAbsolutePath().normalize()
    val expectedRuntimeRoot = normalizedAppHome.resolve("python-runtime")
    val issues = buildList {
        if (!managed.present) add(managed.detail)
        if (managed.root?.toAbsolutePath()?.normalize() != expectedRuntimeRoot) {
            add("Managed Python runtime was not resolved from native app resources.")
        }
        if (python?.available != true) {
            add(python?.detail ?: "Managed Python runtime executable was not available.")
        }
        if (!Files.isRegularFile(brainScript)) {
            add("Packaged brain entry point was not available.")
        }
    }
    return PackagedRuntimeSmokeReport(
        status = if (issues.isEmpty()) "ready" else "not-ready",
        platform = desktopHostPlatform(),
        appVersion = CompanionIdentity.appVersion,
        protocol = CompanionIdentity.protocol,
        resourcesDirectory = normalizedAppHome,
        runtimeRoot = managed.root,
        runtimeManifest = managed.manifestPath,
        runtimeExecutable = managed.pythonPath,
        runtimePresent = managed.present,
        pythonAvailable = python?.available == true,
        pythonVersion = python?.version.orEmpty(),
        brainScript = brainScript.toAbsolutePath().normalize(),
        brainScriptAvailable = Files.isRegularFile(brainScript),
        issues = issues,
    )
}

internal fun writePackagedRuntimeSmoke(outputPath: Path): PackagedRuntimeSmokeReport {
    val report = inspectPackagedRuntimeSmoke()
    outputPath.toAbsolutePath().normalize().parent?.let(Files::createDirectories)
    Files.writeString(outputPath, report.toJson())
    return report
}

private fun desktopHostPlatform(): String {
    val osName = System.getProperty("os.name").lowercase()
    return when {
        "win" in osName -> "windows"
        "mac" in osName || "darwin" in osName -> "macos"
        else -> "linux"
    }
}
