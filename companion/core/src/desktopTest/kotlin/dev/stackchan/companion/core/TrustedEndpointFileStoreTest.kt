package dev.stackchan.companion.core

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

class TrustedEndpointFileStoreTest {
    @Test
    fun missingFileLoadsEmptyRegistry() {
        val store = TrustedEndpointFileStore(Files.createTempDirectory("stackchan-empty-store").resolve("trust.json"))

        assertEquals(emptyList(), store.load().snapshot().endpoints)
    }

    @Test
    fun storeSavesAndLoadsTrustedEndpoints() {
        val path = Files.createTempDirectory("stackchan-trust-store").resolve("trust.json")
        val store = TrustedEndpointFileStore(path)
        val registry = TrustedEndpointRegistry()
        registry.upsert(endpoint("pc-studio-01", "pc", priority = 80))

        store.save(registry)
        val loaded = store.load()

        assertEquals(registry.snapshot(), loaded.snapshot())
        assertEquals("pc-studio-01", loaded.snapshot().endpoints.single().endpointId)
    }

    @Test
    fun storeUpdatePersistsForget() {
        val path = Files.createTempDirectory("stackchan-trust-update").resolve("nested").resolve("trust.json")
        val store = TrustedEndpointFileStore(path)
        store.update { it.upsert(endpoint("phone-rob-01", "android")) }
        store.update { it.forget("phone-rob-01") }

        val loaded = store.load()

        assertFalse(loaded.canAutoConnect("phone-rob-01"))
        assertEquals(emptyList(), loaded.snapshot().endpoints)
    }

    @Test
    fun storeRejectsCorruptOrInvalidRegistryFile() {
        val path = Files.createTempDirectory("stackchan-trust-invalid").resolve("trust.json")
        Files.writeString(
            path,
            """
            {
              "version": 1,
              "endpoints": [
                {"endpoint_id":"dup","endpoint_kind":"pc"},
                {"endpoint_id":"dup","endpoint_kind":"pc"}
              ]
            }
            """.trimIndent(),
        )

        assertFailsWith<IllegalArgumentException> {
            TrustedEndpointFileStore(path).load()
        }
    }

    private fun endpoint(
        id: String,
        kind: String,
        priority: Int = 50,
    ): TrustedEndpoint =
        TrustedEndpoint(
            endpointId = id,
            endpointName = id,
            endpointKind = kind,
            publicKeyFingerprint = "sha256:1111222233334444",
            priority = priority,
            autoConnect = true,
            capabilities = listOf("settings", "diagnostics"),
            lastSeenMs = 0,
        )
}
