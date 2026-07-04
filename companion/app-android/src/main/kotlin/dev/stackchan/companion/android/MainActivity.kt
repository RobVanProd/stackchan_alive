package dev.stackchan.companion.android

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView
import dev.stackchan.companion.core.CompanionIdentity

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(48, 48, 48, 48)
        }

        layout.addView(TextView(this).apply {
            text = CompanionIdentity.displayName
            textSize = 24f
        })
        layout.addView(TextView(this).apply {
            text = "Target: Android"
            textSize = 16f
        })
        layout.addView(TextView(this).apply {
            text = "Version: ${CompanionIdentity.appVersion}"
            textSize = 16f
        })
        layout.addView(TextView(this).apply {
            text = "Protocol: ${CompanionIdentity.protocol}"
            textSize = 16f
        })

        setContentView(layout)
    }
}
