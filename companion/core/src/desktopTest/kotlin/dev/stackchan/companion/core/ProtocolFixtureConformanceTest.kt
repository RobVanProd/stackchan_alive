package dev.stackchan.companion.core

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import kotlin.io.path.extension
import kotlin.io.path.name
import kotlin.io.path.relativeTo
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.JsonObject

class ProtocolFixtureConformanceTest {
    private val fixtureRoot: Path = findFixtureRoot()

    @Test
    fun kotlinDecodesEveryValidProtocolFixture() {
        validFixtureFiles().forEach { path ->
            val relativePath = path.relativeTo(fixtureRoot).toString()
            val decoded = decodeControlMessage(Files.readString(path))

            if (path.name == "unknown_future_message.json") {
                assertIs<UnknownMessage>(decoded, relativePath)
            } else {
                assertFalse(decoded is UnknownMessage, relativePath)
            }
        }
    }

    @Test
    fun kotlinRoundTripsValidFixturesAsControlMessages() {
        validFixtureFiles().forEach { path ->
            val relativePath = path.relativeTo(fixtureRoot).toString()
            val decoded = decodeControlMessage(Files.readString(path))
            val encoded = encodeControlMessage(decoded)
            val reparsed = companionJson.parseToJsonElement(encoded)

            assertIs<JsonObject>(reparsed, relativePath)
            assertEquals(decoded.type, decodeControlMessage(encoded).type, relativePath)
        }
    }

    @Test
    fun kotlinRejectsInvalidProtocolFixtures() {
        invalidFixtureFiles().forEach { path ->
            val relativePath = path.relativeTo(fixtureRoot).toString()
            assertFailsWith<SerializationException>(relativePath) {
                decodeControlMessage(Files.readString(path))
            }
        }
    }

    private fun validFixtureFiles(): List<Path> =
        Files.walk(fixtureRoot).use { stream ->
            stream
                .filter { Files.isRegularFile(it) && it.extension == "json" }
                .filter { !it.relativeTo(fixtureRoot).toString().replace("\\", "/").startsWith("invalid/") }
                .sorted()
                .toList()
        }

    private fun invalidFixtureFiles(): List<Path> =
        Files.walk(fixtureRoot.resolve("invalid")).use { stream ->
            stream
                .filter { Files.isRegularFile(it) && it.extension == "json" }
                .sorted()
                .toList()
        }

    private fun findFixtureRoot(): Path {
        var current = Paths.get(System.getProperty("user.dir")).toAbsolutePath().normalize()
        repeat(6) {
            val candidate = current.resolve("protocol-fixtures")
            if (Files.isDirectory(candidate)) {
                return candidate
            }
            current = current.parent ?: error("Could not locate protocol-fixtures from ${System.getProperty("user.dir")}")
        }
        error("Could not locate protocol-fixtures from ${System.getProperty("user.dir")}")
    }
}
