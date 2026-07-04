package dev.stackchan.companion.desktop

import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import dev.stackchan.companion.core.CompanionIdentity
import dev.stackchan.companion.ui.CompanionConsole

fun main() = application {
    Window(
        onCloseRequest = ::exitApplication,
        title = CompanionIdentity.displayName,
        state = rememberWindowState(width = 1180.dp, height = 820.dp),
    ) {
        CompanionConsole(targetName = "Desktop")
    }
}
