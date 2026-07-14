package dev.stackchan.companion.desktop

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PackagedRuntimeSmokeTest {
    @Test
    fun readyReportRequiresExecutableRuntimeBesideApplication() {
        val appHome = Files.createTempDirectory("stackchan-package-smoke")
        try {
            val runtimeRoot = Files.createDirectories(appHome.resolve("python-runtime"))
            val manifest = Files.writeString(runtimeRoot.resolve("stackchan-python-runtime.json"), "{}")
            val pythonPath = Files.writeString(runtimeRoot.resolve("python.exe"), "fixture")
            val brainScript = Files.writeString(appHome.resolve("lan_service.py"), "# fixture")
            val managed = DesktopManagedPythonRuntimeStatus(true, runtimeRoot, manifest, pythonPath, "ready")
            val python = DesktopPythonRuntimeStatus(
                command = pythonPath.toString(),
                available = true,
                version = "Python 3.12.4",
                scriptAvailable = true,
                workingDirectory = appHome,
                detail = "ready",
                searchedCommands = listOf(pythonPath.toString()),
                managedRuntime = managed,
            )

            val report = buildPackagedRuntimeSmokeReport(appHome, brainScript, managed, python)

            assertEquals("ready", report.status)
            assertTrue(report.runtimePresent)
            assertTrue(report.pythonAvailable)
            assertTrue(report.brainScriptAvailable)
            assertEquals("package-extraction", report.launchContext)
            assertTrue(report.toJson().contains("extracted-native-package-headless-runtime-probe"))
            assertTrue(report.issues.isEmpty())
        } finally {
            appHome.toFile().deleteRecursively()
        }
    }

    @Test
    fun installedLaunchContextIsRecordedWithoutClaimingHumanAcceptance() {
        val appHome = Files.createTempDirectory("stackchan-installed-package-smoke")
        try {
            val runtimeRoot = Files.createDirectories(appHome.resolve("python-runtime"))
            val manifest = Files.writeString(runtimeRoot.resolve("stackchan-python-runtime.json"), "{}")
            val pythonPath = Files.writeString(runtimeRoot.resolve("python.exe"), "fixture")
            val brainScript = Files.writeString(appHome.resolve("lan_service.py"), "# fixture")
            val managed = DesktopManagedPythonRuntimeStatus(true, runtimeRoot, manifest, pythonPath, "ready")
            val python = DesktopPythonRuntimeStatus(
                command = pythonPath.toString(),
                available = true,
                version = "Python 3.12.4",
                scriptAvailable = true,
                workingDirectory = appHome,
                detail = "ready",
                searchedCommands = listOf(pythonPath.toString()),
                managedRuntime = managed,
            )

            val report = buildPackagedRuntimeSmokeReport(appHome, brainScript, managed, python, "installed-package")

            assertEquals("ready", report.status)
            assertEquals("installed-package", report.launchContext)
            assertTrue(report.toJson().contains("installed-native-package-headless-runtime-probe"))
            assertTrue(report.toJson().contains("\"substitutesForTargetInstall\": false"))
        } finally {
            appHome.toFile().deleteRecursively()
        }
    }

    @Test
    fun runtimeOutsideNativeAppResourcesIsRejected() {
        val appHome = Files.createTempDirectory("stackchan-package-smoke-home")
        val externalRoot = Files.createTempDirectory("stackchan-package-smoke-external")
        try {
            val manifest = Files.writeString(externalRoot.resolve("stackchan-python-runtime.json"), "{}")
            val pythonPath = Files.writeString(externalRoot.resolve("python.exe"), "fixture")
            val brainScript = Files.writeString(appHome.resolve("lan_service.py"), "# fixture")
            val managed = DesktopManagedPythonRuntimeStatus(true, externalRoot, manifest, pythonPath, "ready")
            val python = DesktopPythonRuntimeStatus(
                command = pythonPath.toString(),
                available = true,
                version = "Python 3.12.4",
                scriptAvailable = true,
                workingDirectory = appHome,
                detail = "ready",
                searchedCommands = listOf(pythonPath.toString()),
                managedRuntime = managed,
            )

            val report = buildPackagedRuntimeSmokeReport(appHome, brainScript, managed, python)

            assertEquals("not-ready", report.status)
            assertFalse(report.issues.isEmpty())
            assertTrue(report.issues.any { "native app resources" in it })
        } finally {
            appHome.toFile().deleteRecursively()
            externalRoot.toFile().deleteRecursively()
        }
    }
}
