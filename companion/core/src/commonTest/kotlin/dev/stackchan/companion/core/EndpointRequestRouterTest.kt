package dev.stackchan.companion.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class EndpointRequestRouterTest {
    @Test
    fun routerAnswersSettingsGetAndSet() {
        val router = EndpointRequestRouter()

        val setResponse = assertIs<SettingsResult>(
            router.handle(
                SettingsSet(
                    version = 1,
                    settings = buildJsonObject {
                        put("display", buildJsonObject {
                            put("brightness", JsonPrimitive(52))
                        })
                    },
                ),
            ),
        )
        val snapshot = assertIs<SettingsSnapshot>(
            router.handle(SettingsGet(domains = listOf("display"))),
        )

        assertTrue(setResponse.ok)
        assertEquals(2, setResponse.version)
        assertEquals(2, snapshot.version)
        assertEquals(
            52,
            snapshot.settings["display"]!!.jsonObject["brightness"]!!.jsonPrimitive.content.toInt(),
        )
    }

    @Test
    fun routerReportsLockedSettingsAsFailedSettingsResult() {
        val router = EndpointRequestRouter()

        val response = assertIs<SettingsResult>(
            router.handle(
                SettingsSet(
                    version = 1,
                    settings = buildJsonObject {
                        put("motion", buildJsonObject {
                            put("servo_enabled", JsonPrimitive(true))
                        })
                    },
                ),
            ),
        )

        assertFalse(response.ok)
        assertEquals(1, response.version)
    }

    @Test
    fun routerAnswersTrustedEndpointsAndForgetEndpoint() {
        val registry = TrustedEndpointRegistry()
        registry.upsert(
            TrustedEndpoint(
                endpointId = "phone-rob-01",
                endpointName = "Rob's Phone",
                endpointKind = "android",
                publicKeyFingerprint = "sha256:1111222233334444",
                priority = 80,
                autoConnect = true,
                capabilities = listOf("settings"),
            ),
        )
        val router = EndpointRequestRouter(trustedEndpointRegistry = registry)

        val trusted = assertIs<TrustedEndpointsResult>(router.handle(TrustedEndpoints()))
        val forget = assertIs<ForgetEndpointResult>(router.handle(ForgetEndpoint(endpointId = "phone-rob-01")))
        val after = assertIs<TrustedEndpointsResult>(router.handle(TrustedEndpoints()))

        assertEquals("phone-rob-01", trusted.endpoints.single().endpointId)
        assertTrue(forget.ok)
        assertEquals(emptyList(), after.endpoints)
    }

    @Test
    fun routerRunsPersistenceCallbacksAfterSuccessfulMutationsOnly() {
        var settingsCallbacks = 0
        var trustCallbacks = 0
        val registry = TrustedEndpointRegistry()
        registry.upsert(
            TrustedEndpoint(
                endpointId = "studio-mac-01",
                endpointKind = "pc",
                publicKeyFingerprint = "sha256:1111222233334444",
            ),
        )
        val router = EndpointRequestRouter(
            trustedEndpointRegistry = registry,
            onSettingsChanged = { settingsCallbacks += 1 },
            onTrustedEndpointsChanged = { trustCallbacks += 1 },
        )

        router.handle(
            SettingsSet(
                version = 1,
                settings = buildJsonObject {
                    put("motion", buildJsonObject {
                        put("servo_enabled", JsonPrimitive(true))
                    })
                },
            ),
        )
        router.handle(
            SettingsSet(
                version = 1,
                settings = buildJsonObject {
                    put("display", buildJsonObject {
                        put("brightness", JsonPrimitive(60))
                    })
                },
            ),
        )
        router.handle(ForgetEndpoint(endpointId = "missing-endpoint"))
        router.handle(ForgetEndpoint(endpointId = "studio-mac-01"))

        assertEquals(1, settingsCallbacks)
        assertEquals(1, trustCallbacks)
    }

    @Test
    fun routerIgnoresTelemetryMessages() {
        val router = EndpointRequestRouter()

        assertEquals(null, router.handle(Heartbeat(seq = 1)))
    }
}
