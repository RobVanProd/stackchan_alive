package dev.stackchan.companion.android

import dev.stackchan.companion.core.EndpointSessionSnapshot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

data class AndroidBridgeRuntimeStatus(
    val manualBridgeUrls: List<String> = emptyList(),
    val serviceStatus: String = "Starting",
    val serviceDetail: String = "Preparing foreground bridge service.",
    val robotConnected: Boolean = false,
    val robotId: String = "",
    val robotName: String = "",
    val firmwareVersion: String = "",
    val lastMessageType: String = "",
    val activeBrainOwner: String = "",
) {
    val primaryBridgeUrl: String
        get() = manualBridgeUrls.firstOrNull() ?: primaryBridgeManualUrl()

    val robotDisplayName: String
        get() = robotName.ifBlank { robotId.ifBlank { "Awaiting Stackchan robot" } }

    val robotFingerprint: String
        get() = firmwareVersion.ifBlank { if (robotConnected) robotId else "No robot hello yet" }

    val robotState: String
        get() = if (robotConnected) lastMessageType.ifBlank { "connected" } else "Awaiting robot"

    val connectionLabel: String
        get() = if (robotConnected) {
            "Connected: $robotDisplayName"
        } else if (serviceStatus == "Failed") {
            "Bridge failed: $primaryBridgeUrl"
        } else if (serviceStatus == "Stopped") {
            "Bridge stopped: $primaryBridgeUrl"
        } else {
            "Bridge ready: $primaryBridgeUrl"
        }

    val consoleMessage: String
        get() = if (robotConnected) {
            "Robot $robotDisplayName last reported `${lastMessageType.ifBlank { "connected" }}`; brain owner: ${activeBrainOwner.ifBlank { "None" }}."
        } else {
            "Awaiting Stack-chan bridge handshake at $primaryBridgeUrl."
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
            it.copy(
                serviceStatus = status,
                serviceDetail = detail,
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
                    robotConnected = false,
                )
            }
        }
    }

    fun updateSession(snapshot: EndpointSessionSnapshot, detail: String) {
        mutableStatus.update {
            it.copy(
                serviceStatus = "Foreground",
                serviceDetail = detail,
                robotConnected = snapshot.connected,
                robotId = snapshot.deviceId,
                robotName = snapshot.deviceName,
                firmwareVersion = snapshot.firmwareVersion,
                lastMessageType = snapshot.lastMessageType,
                activeBrainOwner = snapshot.activeBrainOwner.orEmpty(),
            )
        }
    }
}
