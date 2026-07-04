package dev.stackchan.companion.core

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class SettingsRepositoryFileStoreTest {
    @Test
    fun missingFileLoadsDefaultSettings() {
        val store = SettingsRepositoryFileStore(
            Files.createTempDirectory("stackchan-empty-settings").resolve("settings.json"),
        )

        val snapshot = store.load().snapshot(listOf("display"))

        assertEquals(1, snapshot.version)
        assertEquals(80, snapshot.settings["display"]!!.jsonObject["brightness"]!!.jsonPrimitive.content.toInt())
    }

    @Test
    fun storeSavesAndLoadsSettingsState() {
        val path = Files.createTempDirectory("stackchan-settings-store").resolve("settings.json")
        val store = SettingsRepositoryFileStore(path)
        val repository = SettingsRepository()
        val outcome = repository.set(
            expectedVersion = 1,
            patch = buildJsonObject {
                put("display", buildJsonObject {
                    put("brightness", JsonPrimitive(45))
                })
                put("bridge", buildJsonObject {
                    put("preferred_mode_policy", JsonPrimitive("mobile_preferred"))
                })
            },
        )

        store.save(repository)
        val loaded = store.load()
        val snapshot = loaded.snapshot(listOf("display", "bridge"))

        assertTrue(outcome.result.ok)
        assertEquals(2, snapshot.version)
        assertEquals(45, snapshot.settings["display"]!!.jsonObject["brightness"]!!.jsonPrimitive.content.toInt())
        assertEquals(
            "mobile_preferred",
            snapshot.settings["bridge"]!!.jsonObject["preferred_mode_policy"]!!.jsonPrimitive.content,
        )
    }

    @Test
    fun storeUpdatePersistsSuccessfulMutation() {
        val path = Files.createTempDirectory("stackchan-settings-update")
            .resolve("nested")
            .resolve("settings.json")
        val store = SettingsRepositoryFileStore(path)

        val updated = store.update { repository ->
            repository.set(
                expectedVersion = 1,
                patch = buildJsonObject {
                    put("privacy", buildJsonObject {
                        put("export_logs", JsonPrimitive(true))
                    })
                },
            )
        }
        val loaded = store.load()

        assertEquals(2, updated.snapshot().version)
        assertEquals(
            true,
            loaded.snapshot(listOf("privacy"))
                .settings["privacy"]!!
                .jsonObject["export_logs"]!!
                .jsonPrimitive
                .content
                .toBoolean(),
        )
    }

    @Test
    fun storeFillsMissingDomainsFromDefaults() {
        val path = Files.createTempDirectory("stackchan-settings-partial").resolve("settings.json")
        Files.writeString(
            path,
            """
            {
              "version": 3,
              "settings": {
                "display": {
                  "brightness": 35
                }
              }
            }
            """.trimIndent(),
        )

        val snapshot = SettingsRepositoryFileStore(path).load().snapshot(listOf("display", "voice"))

        assertEquals(3, snapshot.version)
        assertEquals(35, snapshot.settings["display"]!!.jsonObject["brightness"]!!.jsonPrimitive.content.toInt())
        assertEquals("review_synth", snapshot.settings["voice"]!!.jsonObject["profile"]!!.jsonPrimitive.content)
    }

    @Test
    fun storeRejectsCorruptOrInvalidSettingsFile() {
        val path = Files.createTempDirectory("stackchan-settings-invalid").resolve("settings.json")
        Files.writeString(
            path,
            """
            {
              "version": 1,
              "settings": {
                "unknown": {}
              }
            }
            """.trimIndent(),
        )

        assertFailsWith<IllegalArgumentException> {
            SettingsRepositoryFileStore(path).load()
        }
    }
}
