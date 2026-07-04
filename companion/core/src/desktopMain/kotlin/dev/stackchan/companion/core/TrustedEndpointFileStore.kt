package dev.stackchan.companion.core

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption

class TrustedEndpointFileStore(
    private val path: Path,
) {
    fun load(): TrustedEndpointRegistry {
        if (!Files.exists(path)) {
            return TrustedEndpointRegistry()
        }
        return TrustedEndpointRegistry.decode(Files.readString(path))
    }

    fun save(registry: TrustedEndpointRegistry) {
        val parent = path.parent ?: Path.of(".")
        Files.createDirectories(parent)
        val temp = Files.createTempFile(parent, "${path.fileName}.", ".tmp")
        try {
            Files.writeString(temp, registry.encode())
            runCatching {
                Files.move(
                    temp,
                    path,
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            }.getOrElse {
                Files.move(temp, path, StandardCopyOption.REPLACE_EXISTING)
            }
        } finally {
            Files.deleteIfExists(temp)
        }
    }

    fun update(mutator: (TrustedEndpointRegistry) -> Unit): TrustedEndpointRegistry {
        val registry = load()
        mutator(registry)
        save(registry)
        return registry
    }
}
