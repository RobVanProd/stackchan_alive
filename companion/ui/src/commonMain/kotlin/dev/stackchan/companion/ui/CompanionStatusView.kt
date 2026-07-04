package dev.stackchan.companion.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.stackchan.companion.core.CompanionIdentity

@Composable
fun CompanionStatusView(targetName: String) {
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier.padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    text = CompanionIdentity.displayName,
                    style = MaterialTheme.typography.headlineSmall,
                )
                Text(text = "Target: $targetName")
                Text(text = "Version: ${CompanionIdentity.appVersion}")
                Text(text = "Protocol: ${CompanionIdentity.protocol}")
            }
        }
    }
}
