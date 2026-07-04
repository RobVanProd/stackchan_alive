package dev.stackchan.companion.android

import dev.stackchan.companion.core.DEFAULT_BRIDGE_BEACON_PORT
import dev.stackchan.companion.core.DEFAULT_BRIDGE_PORT
import dev.stackchan.companion.core.EndpointHello
import dev.stackchan.companion.core.encodeUdpBridgeBeacon
import dev.stackchan.companion.core.endpointHelloToBeacon
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class AndroidUdpBeaconBroadcaster(
    private val endpointHello: EndpointHello,
    private val bridgePort: Int = DEFAULT_BRIDGE_PORT,
    private val targetPort: Int = DEFAULT_BRIDGE_BEACON_PORT,
    private val targetHost: String = BROADCAST_HOST,
    private val intervalMs: Long = BEACON_INTERVAL_MS,
    private val onStatusChanged: (String) -> Unit = {},
) : AutoCloseable {
    private var job: Job? = null

    fun start(scope: CoroutineScope) {
        if (job?.isActive == true) {
            return
        }
        require(bridgePort in 1..65535) { "bridge port must be 1..65535" }
        require(targetPort in 1..65535) { "target port must be 1..65535" }
        require(intervalMs > 0) { "intervalMs must be positive" }

        val payload = encodeUdpBridgeBeacon(endpointHelloToBeacon(endpointHello, bridgePort)).encodeToByteArray()
        val targetAddress = InetAddress.getByName(targetHost)
        job = scope.launch(Dispatchers.IO) {
            var reportedFailure = false
            while (isActive) {
                runCatching { send(payload, targetAddress) }
                    .onSuccess { reportedFailure = false }
                    .onFailure { error ->
                        if (!reportedFailure) {
                            reportedFailure = true
                            onStatusChanged("Bridge ready; UDP beacon unavailable: ${error.message ?: error::class.simpleName}")
                        }
                    }
                delay(intervalMs)
            }
        }
    }

    override fun close() {
        job?.cancel()
        job = null
    }

    private fun send(payload: ByteArray, targetAddress: InetAddress) {
        DatagramSocket().use { socket ->
            socket.broadcast = true
            socket.send(DatagramPacket(payload, payload.size, targetAddress, targetPort))
        }
    }

    private companion object {
        const val BROADCAST_HOST = "255.255.255.255"
        const val BEACON_INTERVAL_MS = 5_000L
    }
}
