package dev.stackchan.companion.android

import android.content.Context
import dev.stackchan.companion.core.SettingsRepository
import dev.stackchan.companion.core.TrustedEndpointRegistry
import java.util.UUID

class AndroidBridgeStores(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun endpointId(): String {
        prefs.getString(KEY_ENDPOINT_ID, null)?.let { return it }
        val endpointId = "android-companion-${UUID.randomUUID()}"
        prefs.edit().putString(KEY_ENDPOINT_ID, endpointId).apply()
        return endpointId
    }

    fun loadSettings(): SettingsRepository =
        prefs.getString(KEY_SETTINGS, null)
            ?.let { text -> runCatching { SettingsRepository.decode(text) }.getOrNull() }
            ?: SettingsRepository()

    fun saveSettings(repository: SettingsRepository) {
        prefs.edit().putString(KEY_SETTINGS, repository.encode()).apply()
    }

    fun loadTrustedEndpoints(): TrustedEndpointRegistry =
        prefs.getString(KEY_TRUSTED_ENDPOINTS, null)
            ?.let { text -> runCatching { TrustedEndpointRegistry.decode(text) }.getOrNull() }
            ?: TrustedEndpointRegistry()

    fun saveTrustedEndpoints(registry: TrustedEndpointRegistry) {
        prefs.edit().putString(KEY_TRUSTED_ENDPOINTS, registry.encode()).apply()
    }

    private companion object {
        const val PREFS_NAME = "stackchan_android_bridge"
        const val KEY_ENDPOINT_ID = "endpoint_id"
        const val KEY_SETTINGS = "settings_repository"
        const val KEY_TRUSTED_ENDPOINTS = "trusted_endpoints"
    }
}
