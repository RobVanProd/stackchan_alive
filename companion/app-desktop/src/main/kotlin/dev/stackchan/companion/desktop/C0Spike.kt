package dev.stackchan.companion.desktop

import dev.stackchan.companion.core.CompanionIdentity
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO as ClientCIO
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.webSocket
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import io.ktor.server.routing.routing
import io.ktor.server.websocket.WebSockets as ServerWebSockets
import io.ktor.server.websocket.webSocket
import io.ktor.websocket.Frame
import io.ktor.websocket.readText
import java.awt.GraphicsEnvironment
import java.awt.SystemTray
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.file.Files
import java.nio.file.Path
import java.time.Instant
import javax.jmdns.JmDNS
import javax.jmdns.ServiceInfo
import kotlinx.coroutines.runBlocking

fun main(args: Array<String>) {
    val outDir = Path.of(args.firstOrNull() ?: "output/companion/c0-spike")
    Files.createDirectories(outDir)
    val report = runC0Spike()
    Files.writeString(outDir.resolve("SPIKE.md"), report.toMarkdown())
    if (!report.websocketLoopback || !report.mdnsAdvertise) {
        error("C0 spike failed; see ${outDir.resolve("SPIKE.md")}")
    }
}

data class C0SpikeReport(
    val generatedAt: Instant,
    val appVersion: String,
    val protocol: String,
    val websocketLoopback: Boolean,
    val mdnsAdvertise: Boolean,
    val traySupported: Boolean,
    val headless: Boolean,
    val idleMillis: Long,
    val notes: List<String>,
) {
    fun toMarkdown(): String = buildString {
        appendLine("# Companion C0 Spike")
        appendLine()
        appendLine("- generated_at: `$generatedAt`")
        appendLine("- app_version: `$appVersion`")
        appendLine("- protocol: `$protocol`")
        appendLine("- websocket_loopback: `$websocketLoopback`")
        appendLine("- mdns_advertise: `$mdnsAdvertise`")
        appendLine("- tray_supported: `$traySupported`")
        appendLine("- java_headless: `$headless`")
        appendLine("- idle_millis: `$idleMillis`")
        appendLine()
        appendLine("## Notes")
        notes.forEach { appendLine("- $it") }
    }
}

fun runC0Spike(): C0SpikeReport {
    val notes = mutableListOf<String>()
    val websocketOk = runBlocking { runWebsocketLoopback(notes) }
    val mdnsOk = runMdnsAdvertise(notes)
    val headless = GraphicsEnvironment.isHeadless()
    val traySupported = !headless && SystemTray.isSupported()
    val idleMillis = System.getProperty("idleMillis")?.toLongOrNull() ?: 1_000L
    Thread.sleep(idleMillis)

    if (!traySupported) {
        notes += "Tray support is unavailable in this environment; run on a desktop Ubuntu session for the 30-minute tray soak gate."
    }

    return C0SpikeReport(
        generatedAt = Instant.now(),
        appVersion = CompanionIdentity.appVersion,
        protocol = CompanionIdentity.protocol,
        websocketLoopback = websocketOk,
        mdnsAdvertise = mdnsOk,
        traySupported = traySupported,
        headless = headless,
        idleMillis = idleMillis,
        notes = notes,
    )
}

private suspend fun runWebsocketLoopback(notes: MutableList<String>): Boolean {
    val port = findFreeLoopbackPort()
    val server = embeddedServer(CIO, host = "127.0.0.1", port = port) {
        install(ServerWebSockets)
        routing {
            webSocket("/bridge") {
                val received = incoming.receive()
                val text = (received as? Frame.Text)?.readText().orEmpty()
                send(Frame.Text("ack:$text"))
            }
        }
    }.start(wait = false)

    return try {
        val client = HttpClient(ClientCIO) {
            install(WebSockets)
        }
        var response = ""
        client.webSocket(host = "127.0.0.1", port = port, path = "/bridge") {
            send(Frame.Text(CompanionIdentity.protocol))
            response = (incoming.receive() as Frame.Text).readText()
        }
        client.close()
        val ok = response == "ack:${CompanionIdentity.protocol}"
        notes += "Ktor CIO WebSocket loopback on 127.0.0.1:$port returned `$response`."
        ok
    } catch (exception: Exception) {
        notes += "Ktor CIO WebSocket loopback failed: ${exception::class.simpleName}: ${exception.message}"
        false
    } finally {
        server.stop()
    }
}

private fun findFreeLoopbackPort(): Int =
    ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }

private fun runMdnsAdvertise(notes: MutableList<String>): Boolean {
    val jmdns = JmDNS.create(InetAddress.getLoopbackAddress(), "stackchan-companion-c0")
    val serviceInfo = ServiceInfo.create(
        "_stackchan-bridge._tcp.local.",
        "Stackchan Companion C0",
        8765,
        "endpoint_id=pc-companion-c0,endpoint_kind=pc,proto=${CompanionIdentity.protocol}",
    )

    return try {
        jmdns.registerService(serviceInfo)
        notes += "jmDNS registered `_stackchan-bridge._tcp.local.` on loopback with proto `${CompanionIdentity.protocol}`."
        true
    } catch (exception: Exception) {
        notes += "jmDNS advertise failed: ${exception::class.simpleName}: ${exception.message}"
        false
    } finally {
        runCatching { jmdns.unregisterService(serviceInfo) }
        runCatching { jmdns.close() }
    }
}
