package dev.stackchan.companion.desktop

import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import dev.stackchan.companion.core.CompanionIdentity
import dev.stackchan.companion.ui.CompanionStatusView

fun main() = application {
    Window(
        onCloseRequest = ::exitApplication,
        title = CompanionIdentity.displayName,
    ) {
        CompanionStatusView(targetName = "Desktop")
    }
}
