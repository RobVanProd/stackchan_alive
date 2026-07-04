package dev.stackchan.companion.desktop

import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import dev.stackchan.companion.core.CompanionIdentity
import dev.stackchan.companion.ui.CompanionStatusView

fun main() {
    val runtime = DesktopCompanionRuntime().start()
    Runtime.getRuntime().addShutdownHook(Thread { runtime.close() })

    application {
        Window(
            onCloseRequest = {
                runtime.close()
                exitApplication()
            },
            title = CompanionIdentity.displayName,
        ) {
            CompanionStatusView(targetName = "Desktop")
        }
    }
}
