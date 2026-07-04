package dev.stackchan.companion.android

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import dev.stackchan.companion.core.EndpointHello
import dev.stackchan.companion.core.STACKCHAN_BRIDGE_SERVICE

class AndroidBridgeAdvertisement(
    context: Context,
    private val endpointHello: EndpointHello,
    private val port: Int,
    private val onStatusChanged: (String) -> Unit = {},
) : AutoCloseable {
    private val appContext = context.applicationContext
    private val nsdManager = appContext.getSystemService(NsdManager::class.java)
    private val wifiManager = appContext.getSystemService(WifiManager::class.java)
    private var multicastLock: WifiManager.MulticastLock? = null
    private var listener: NsdManager.RegistrationListener? = null

    fun start() {
        if (listener != null) {
            return
        }
        require(port in 1..65535) { "port must be 1..65535" }

        acquireMulticastLock()
        val serviceInfo = NsdServiceInfo().apply {
            serviceName = endpointHello.endpointName
            serviceType = ANDROID_BRIDGE_SERVICE_TYPE
            setPort(port)
            setAttribute("endpoint_id", endpointHello.endpointId)
            setAttribute("endpoint_kind", endpointHello.endpointKind)
            setAttribute("proto", endpointHello.protocol)
            setAttribute("capabilities", endpointHello.capabilities.joinToString(","))
        }
        val registrationListener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                onStatusChanged("Bridge advertised as ${serviceInfo.serviceName}.$STACKCHAN_BRIDGE_SERVICE")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                listener = null
                releaseMulticastLock()
                onStatusChanged("Bridge ready; NSD advertise failed ($errorCode)")
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) = Unit

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                onStatusChanged("Bridge stopped; NSD unregistration failed ($errorCode)")
            }
        }
        listener = registrationListener
        try {
            nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener)
        } catch (error: RuntimeException) {
            listener = null
            releaseMulticastLock()
            throw error
        }
    }

    override fun close() {
        val registrationListener = listener
        listener = null
        if (registrationListener != null) {
            runCatching { nsdManager.unregisterService(registrationListener) }
        }
        releaseMulticastLock()
    }

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) {
            return
        }
        multicastLock = wifiManager.createMulticastLock(MULTICAST_LOCK_TAG).apply {
            setReferenceCounted(false)
            runCatching { acquire() }
                .onFailure { onStatusChanged("Bridge ready; multicast lock unavailable") }
        }
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { lock ->
            runCatching {
                if (lock.isHeld) {
                    lock.release()
                }
            }
        }
        multicastLock = null
    }

    companion object {
        private const val MULTICAST_LOCK_TAG = "stackchan_companion_nsd"
        val ANDROID_BRIDGE_SERVICE_TYPE: String = STACKCHAN_BRIDGE_SERVICE.removeSuffix(".local") + "."
    }
}
