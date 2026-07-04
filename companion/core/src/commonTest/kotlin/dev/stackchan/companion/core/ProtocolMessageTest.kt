package dev.stackchan.companion.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonObject

class ProtocolMessageTest {
    @Test
    fun endpointHelloUsesBridgeProtocolAndSnakeCaseFields() {
        val encoded = companionJson.encodeToString(EndpointHello.serializer(), defaultAndroidEndpointHello())
        val decoded = companionJson.decodeFromString(EndpointHello.serializer(), encoded)
        val parsed = companionJson.parseToJsonElement(encoded) as JsonObject

        assertEquals(CompanionIdentity.protocol, decoded.protocol)
        assertTrue("endpoint_id" in parsed)
    }

    @Test
    fun unknownFieldsAreIgnoredForForwardCompatibility() {
        val decoded = companionJson.decodeFromString(
            EndpointHello.serializer(),
            """
            {
              "type": "endpoint_hello",
              "protocol": "stackchan.bridge.v1",
              "endpoint_id": "phone-rob-01",
              "endpoint_name": "Rob's Phone",
              "endpoint_kind": "android",
              "app_version": "0.1.0",
              "priority": 60,
              "supports_binary_audio": true,
              "capabilities": ["settings"],
              "future_field": "ignored"
            }
            """.trimIndent(),
        )

        assertEquals("phone-rob-01", decoded.endpointId)
        assertEquals("settings", decoded.capabilities.single())
    }
}
