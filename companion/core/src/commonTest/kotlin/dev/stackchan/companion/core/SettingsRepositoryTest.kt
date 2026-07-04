package dev.stackchan.companion.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class SettingsRepositoryTest {
    @Test
    fun settingsGetReturnsRequestedDomainsOnly() {
        val repository = SettingsRepository()

        val snapshot = repository.handleGet(SettingsGet(domains = listOf("display", "bridge")))

        assertEquals(1, snapshot.version)
        assertEquals(setOf("display", "bridge"), snapshot.settings.keys)
    }

    @Test
    fun settingsSetMergesPatchAndIncrementsVersion() {
        val repository = SettingsRepository()

        val outcome = repository.handleSet(
            SettingsSet(
                version = 1,
                settings = buildJsonObject {
                    put("display", buildJsonObject {
                        put("brightness", JsonPrimitive(42))
                    })
                    put("bridge", buildJsonObject {
                        put("preferred_mode_policy", JsonPrimitive("mobile_preferred"))
                    })
                },
            ),
        )
        val snapshot = repository.snapshot(listOf("display", "bridge"))

        assertTrue(outcome.result.ok)
        assertEquals(2, outcome.result.version)
        assertEquals(42, snapshot.settings["display"]!!.jsonObject["brightness"]!!.jsonPrimitive.content.toInt())
        assertEquals(false, snapshot.settings["display"]!!.jsonObject["reduced_motion"]!!.jsonPrimitive.content.toBoolean())
        assertEquals("mobile_preferred", snapshot.settings["bridge"]!!.jsonObject["preferred_mode_policy"]!!.jsonPrimitive.content)
    }

    @Test
    fun settingsSetRejectsVersionConflictWithoutChangingState() {
        val repository = SettingsRepository()

        val outcome = repository.handleSet(
            SettingsSet(
                version = 99,
                settings = buildJsonObject {
                    put("display", buildJsonObject {
                        put("brightness", JsonPrimitive(10))
                    })
                },
            ),
        )

        assertFalse(outcome.result.ok)
        assertEquals("version_conflict", outcome.errorCode)
        assertEquals(1, outcome.result.version)
        assertEquals(80, repository.snapshot(listOf("display")).settings["display"]!!.jsonObject["brightness"]!!.jsonPrimitive.content.toInt())
    }

    @Test
    fun settingsSetRejectsFoundationLockedFields() {
        val repository = SettingsRepository()

        val outcome = repository.handleSet(
            SettingsSet(
                version = 1,
                settings = buildJsonObject {
                    put("motion", buildJsonObject {
                        put("servo_enabled", JsonPrimitive(true))
                    })
                    put("privacy", buildJsonObject {
                        put("wake_gate", JsonPrimitive(false))
                    })
                },
            ),
        )

        assertFalse(outcome.result.ok)
        assertEquals("settings_locked", outcome.errorCode)
        assertEquals(listOf("motion.servo_enabled", "privacy.wake_gate"), outcome.rejectedPaths)
        assertEquals(1, repository.snapshot().version)
    }

    @Test
    fun safeSettingsRemainWritable() {
        val repository = SettingsRepository()

        val outcome = repository.handleSet(
            SettingsSet(
                version = 1,
                settings = buildJsonObject {
                    put("display", buildJsonObject {
                        put("reduced_motion", JsonPrimitive(true))
                    })
                    put("privacy", buildJsonObject {
                        put("export_logs", JsonPrimitive(true))
                    })
                },
            ),
        )

        assertTrue(outcome.result.ok)
        assertEquals(true, repository.snapshot(listOf("privacy")).settings["privacy"]!!.jsonObject["export_logs"]!!.jsonPrimitive.content.toBoolean())
    }

    @Test
    fun repositoryRejectsUnknownDomains() {
        val repository = SettingsRepository()

        assertFailsWith<IllegalArgumentException> {
            repository.snapshot(listOf("unknown"))
        }
        assertFailsWith<IllegalArgumentException> {
            repository.handleSet(
                SettingsSet(
                    version = 1,
                    settings = JsonObject(mapOf("unknown" to JsonObject(emptyMap()))),
                ),
            )
        }
    }
}
