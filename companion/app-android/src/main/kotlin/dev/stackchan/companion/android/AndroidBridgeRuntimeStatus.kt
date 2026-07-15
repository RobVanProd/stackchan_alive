package dev.stackchan.companion.android

import dev.stackchan.companion.core.EndpointSessionSnapshot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

data class AndroidBridgeRuntimeStatus(
    val manualBridgeUrls: List<String> = emptyList(),
    val serviceStatus: String = "Starting",
    val serviceDetail: String = "Preparing foreground bridge service.",
    val robotSocketConnected: Boolean = false,
    val robotConnected: Boolean = false,
    val robotId: String = "",
    val robotName: String = "",
    val firmwareVersion: String = "",
    val lastMessageType: String = "",
    val activeBrainOwner: String = "",
    val textTurnsSubmitted: Int = 0,
    val lastTextTurn: String = "",
    val networkProfile: String = "",
) {
    val primaryBridgeUrl: String
        get() = manualBridgeUrls.firstOrNull() ?: primaryBridgeManualUrl()

    val robotDisplayName: String
        get() = robotName.ifBlank {
            robotId.ifBlank {
                if (robotSocketConnected) "Stackchan detected" else "Awaiting Stackchan robot"
            }
        }

    val robotFingerprint: String
        get() = firmwareVersion.ifBlank {
            when {
                robotConnected -> robotId
                robotSocketConnected -> "Bridge socket open; no robot hello yet"
                else -> "No robot hello yet"
            }
        }

    val robotState: String
        get() = when {
            serviceStatus == "Failed" -> "Bridge failed"
            serviceStatus == "Stopped" -> "Bridge stopped"
            serviceStatus == "Starting" -> "Bridge starting"
            robotConnected -> lastMessageType.ifBlank { "connected" }
            robotSocketConnected -> "Awaiting robot hello"
            else -> "Awaiting robot"
        }

    val connectionLabel: String
        get() = when {
            serviceStatus == "Failed" -> "Bridge failed: $primaryBridgeUrl"
            serviceStatus == "Stopped" -> "Bridge stopped: $primaryBridgeUrl"
            serviceStatus == "Starting" -> "Bridge starting: $primaryBridgeUrl"
            robotConnected -> "Connected: $robotDisplayName"
            robotSocketConnected -> "Robot detected: waiting for hello"
            else -> "Bridge ready: $primaryBridgeUrl"
        }

    val consoleMessage: String
        get() = when {
            serviceStatus == "Failed" -> serviceDetail
            serviceStatus == "Stopped" -> serviceDetail
            serviceStatus == "Starting" -> serviceDetail
            robotConnected -> "Robot $robotDisplayName last reported `${lastMessageType.ifBlank { "connected" }}`; brain owner: ${activeBrainOwner.ifBlank { "None" }}."
            robotSocketConnected -> "Stack-chan opened the bridge socket. Waiting for robot hello before enabling Talk or settings."
            else -> "Awaiting Stack-chan bridge handshake at $primaryBridgeUrl."
        }
}

object AndroidBridgeRuntimeStatusStore {
    private val mutableStatus = MutableStateFlow(AndroidBridgeRuntimeStatus())
    val status: StateFlow<AndroidBridgeRuntimeStatus> = mutableStatus

    fun setManualBridgeUrls(urls: List<String>) {
        mutableStatus.update { it.copy(manualBridgeUrls = urls) }
    }

    fun setServiceStatus(status: String, detail: String) {
        mutableStatus.update {
            val clearSession = status == "Starting" || status == "Failed" || status == "Stopped"
            it.copy(
                serviceStatus = status,
                serviceDetail = detail,
                robotSocketConnected = if (clearSession) false else it.robotSocketConnected,
                robotConnected = if (clearSession) false else it.robotConnected,
                robotId = if (clearSession) "" else it.robotId,
                robotName = if (clearSession) "" else it.robotName,
                firmwareVersion = if (clearSession) "" else it.firmwareVersion,
                lastMessageType = if (clearSession) "" else it.lastMessageType,
                activeBrainOwner = if (clearSession) "" else it.activeBrainOwner,
                textTurnsSubmitted = if (clearSession) 0 else it.textTurnsSubmitted,
                lastTextTurn = if (clearSession) "" else it.lastTextTurn,
                networkProfile = if (clearSession) "" else it.networkProfile,
            )
        }
    }

    fun setStopped(detail: String) {
        mutableStatus.update {
            if (it.serviceStatus == "Failed") {
                it
            } else {
                it.copy(
                    serviceStatus = "Stopped",
                    serviceDetail = detail,
                    robotSocketConnected = false,
                    robotConnected = false,
                    robotId = "",
                    robotName = "",
                    firmwareVersion = "",
                    lastMessageType = "",
                    activeBrainOwner = "",
                    textTurnsSubmitted = 0,
                    lastTextTurn = "",
                    networkProfile = "",
                )
            }
        }
    }

    fun updateSession(snapshot: EndpointSessionSnapshot, detail: String) {
        mutableStatus.update {
            it.copy(
                serviceStatus = "Foreground",
                serviceDetail = detail,
                robotSocketConnected = snapshot.connected,
                robotConnected = snapshot.robotHelloReceived,
                robotId = snapshot.deviceId,
                robotName = snapshot.deviceName,
                firmwareVersion = snapshot.firmwareVersion,
                lastMessageType = snapshot.lastMessageType,
                activeBrainOwner = snapshot.activeBrainOwner.orEmpty(),
                textTurnsSubmitted = snapshot.textTurnsSubmitted,
                lastTextTurn = snapshot.lastTextTurn,
                networkProfile = snapshot.networkProfile,
            )
        }
    }
}
