package dev.stackchan.companion.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import dev.stackchan.companion.core.CompanionEndpointServer
import dev.stackchan.companion.core.DEFAULT_BRIDGE_PORT
import dev.stackchan.companion.core.EndpointRequestRouter
import dev.stackchan.companion.core.EndpointServerConfig
import dev.stackchan.companion.core.defaultAndroidEndpointHello
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class CompanionBridgeService : Service() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var server: CompanionEndpointServer? = null
    private var advertisement: AndroidBridgeAdvertisement? = null
    private var udpBeaconBroadcaster: AndroidUdpBeaconBroadcaster? = null
    private var startJob: Job? = null
    private var wakeLockMonitorJob: Job? = null
    private var sessionWakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        val startingDetail = "Starting bridge at ${primaryBridgeManualUrl()}"
        AndroidBridgeRuntimeStatusStore.setServiceStatus("Starting", startingDetail)
        startForeground(NOTIFICATION_ID, buildNotification(startingDetail))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        ensureServerStarted()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        startJob?.cancel()
        wakeLockMonitorJob?.cancel()
        wakeLockMonitorJob = null
        releaseSessionWakeLock()
        udpBeaconBroadcaster?.close()
        udpBeaconBroadcaster = null
        advertisement?.close()
        advertisement = null
        server?.close()
        server = null
        AndroidBridgeRuntimeStatusStore.setStopped("Android bridge service stopped.")
        serviceScope.cancel()
        super.onDestroy()
    }

    private fun ensureServerStarted() {
        if (server != null || startJob?.isActive == true) {
            return
        }

        startJob = serviceScope.launch {
            val stores = AndroidBridgeStores(applicationContext)
            val settings = stores.loadSettings()
            val trustedEndpoints = stores.loadTrustedEndpoints()
            val endpointHello = defaultAndroidEndpointHello(endpointId = stores.endpointId())
            val router = EndpointRequestRouter(
                settingsRepository = settings,
                trustedEndpointRegistry = trustedEndpoints,
                onSettingsChanged = stores::saveSettings,
                onTrustedEndpointsChanged = stores::saveTrustedEndpoints,
            )

            runCatching {
                CompanionEndpointServer(
                    EndpointServerConfig(
                        host = "0.0.0.0",
                        port = DEFAULT_BRIDGE_PORT,
                        endpointHello = endpointHello,
                        requestRouter = router,
                    ),
                ).start()
            }.onSuccess { bridge ->
                server = bridge
                startWakeLockMonitor(bridge)
                udpBeaconBroadcaster = AndroidUdpBeaconBroadcaster(
                    endpointHello = endpointHello,
                    onStatusChanged = ::updateNotification,
                ).also { it.start(serviceScope) }
                runCatching {
                    AndroidBridgeAdvertisement(
                        context = applicationContext,
                        endpointHello = endpointHello,
                        port = DEFAULT_BRIDGE_PORT,
                        onStatusChanged = ::updateNotification,
                    ).also { it.start() }
                }.onSuccess { bridgeAdvertisement ->
                    advertisement = bridgeAdvertisement
                    updateNotification("Bridge ready at ${primaryBridgeManualUrl()}; advertising NSD")
                }.onFailure { error ->
                    updateNotification("Bridge ready at ${primaryBridgeManualUrl()}; NSD unavailable: ${error.message ?: error::class.simpleName}")
                }
            }.onFailure { error ->
                val failureDetail = "Bridge failed: ${error.message ?: error::class.simpleName}"
                updateNotification(failureDetail, status = "Failed")
                stopSelf()
            }
        }
    }

    private fun startWakeLockMonitor(bridge: CompanionEndpointServer) {
        wakeLockMonitorJob?.cancel()
        wakeLockMonitorJob = serviceScope.launch {
            var wasConnected = false
            while (isActive) {
                val snapshot = runCatching { bridge.currentSnapshot() }.getOrDefault(null)
                val connected = snapshot?.connected == true
                if (connected) {
                    acquireOrRenewSessionWakeLock()
                } else {
                    releaseSessionWakeLock()
                }
                if (connected != wasConnected) {
                    wasConnected = connected
                    val suffix = if (connected) "session wake lock active" else "waiting for robot session"
                    updateNotification("Bridge ready at ${primaryBridgeManualUrl()}; $suffix")
                }
                if (snapshot != null) {
                    val suffix = if (connected) "session wake lock active" else "waiting for robot session"
                    AndroidBridgeRuntimeStatusStore.updateSession(
                        snapshot = snapshot,
                        detail = "Bridge ready at ${primaryBridgeManualUrl()}; $suffix",
                    )
                }
                delay(WAKE_LOCK_POLL_MS)
            }
        }
    }

    private fun acquireOrRenewSessionWakeLock() {
        val lock = sessionWakeLock ?: getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, SESSION_WAKE_LOCK_TAG)
            .apply { setReferenceCounted(false) }
            .also { sessionWakeLock = it }
        runCatching { lock.acquire(WAKE_LOCK_TIMEOUT_MS) }
    }

    private fun releaseSessionWakeLock() {
        sessionWakeLock?.let { lock ->
            runCatching {
                if (lock.isHeld) {
                    lock.release()
                }
            }
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Stackchan bridge",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps the Stackchan robot bridge available on the local network."
        }
        notificationManager().createNotificationChannel(channel)
    }

    private fun updateNotification(contentText: String, status: String = "Foreground") {
        AndroidBridgeRuntimeStatusStore.setServiceStatus(status, contentText)
        notificationManager().notify(NOTIFICATION_ID, buildNotification(contentText))
    }

    private fun buildNotification(contentText: String): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, CompanionBridgeService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stackchan_bridge)
            .setContentTitle("Stackchan companion bridge")
            .setContentText(contentText)
            .setStyle(Notification.BigTextStyle().bigText(contentText))
            .setContentIntent(openIntent)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, R.drawable.ic_stackchan_bridge),
                    "Stop",
                    stopIntent,
                ).build(),
            )
            .build()
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(NotificationManager::class.java)

    companion object {
        private const val CHANNEL_ID = "stackchan_companion_bridge"
        private const val NOTIFICATION_ID = 8765
        private const val ACTION_STOP = "dev.stackchan.companion.android.STOP_BRIDGE"
        private const val SESSION_WAKE_LOCK_TAG = "StackchanCompanion:BridgeSession"
        private const val WAKE_LOCK_TIMEOUT_MS = 60_000L
        private const val WAKE_LOCK_POLL_MS = 15_000L

        fun start(context: Context) {
            val intent = Intent(context, CompanionBridgeService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, CompanionBridgeService::class.java).setAction(ACTION_STOP)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun restart(context: Context) {
            stop(context)
            start(context)
        }
    }
}
