package dev.stackchan.companion.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.serialization.SerializationException
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
              "app_version": "1.0.0",
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

    @Test
    fun codecDecodesEndpointHelloByType() {
        val decoded = decodeControlMessage(
            """
            {
              "type": "endpoint_hello",
              "protocol": "stackchan.bridge.v1",
              "endpoint_id": "phone-rob-01",
              "endpoint_name": "Rob's Phone",
              "endpoint_kind": "android",
              "app_version": "1.0.0",
              "pairing_code": "7K9PQ2",
              "priority": 60,
              "supports_binary_audio": true,
              "capabilities": ["settings", "diagnostics"]
            }
            """.trimIndent(),
        )

        val hello = assertIs<EndpointHello>(decoded)
        assertEquals("phone-rob-01", hello.endpointId)
        assertEquals("android", hello.endpointKind)
        assertEquals("7K9PQ2", hello.pairingCode)
    }

    @Test
    fun codecRejectsProtocolMismatch() {
        assertFailsWith<SerializationException> {
            decodeControlMessage(
                """
                {
                  "type": "endpoint_hello",
                  "protocol": "stackchan.bridge.v2",
                  "endpoint_id": "phone-rob-01",
                  "endpoint_name": "Rob's Phone",
                  "endpoint_kind": "android",
                  "priority": 60,
                  "supports_binary_audio": true,
                  "capabilities": ["settings"]
                }
                """.trimIndent(),
            )
        }
    }

    @Test
    fun codecPreservesUnknownFutureMessages() {
        val decoded = decodeControlMessage(
            """
            {
              "type": "future_probe",
              "protocol": "stackchan.bridge.v1",
              "future_field": "ignored"
            }
            """.trimIndent(),
        )

        val unknown = assertIs<UnknownMessage>(decoded)
        assertEquals("future_probe", unknown.type)
        assertTrue("future_field" in unknown.raw)
    }

    @Test
    fun codecRoundTripsTrustedWifiProfileSwitch() {
        val encoded = encodeControlMessage(
            WifiProfileUse(endpointId = "phone-rob-01", profile = "away"),
        )
        val decoded = assertIs<WifiProfileUse>(decodeControlMessage(encoded))

        assertEquals(CompanionIdentity.protocol, decoded.protocol)
        assertEquals("phone-rob-01", decoded.endpointId)
        assertEquals("away", decoded.profile)
    }
}
