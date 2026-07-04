package dev.stackchan.companion.core

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption

class SettingsRepositoryFileStore(
    private val path: Path,
) {
    fun load(): SettingsRepository {
        if (!Files.exists(path)) {
            return SettingsRepository()
        }
        return SettingsRepository.decode(Files.readString(path))
    }

    fun save(repository: SettingsRepository) {
        val parent = path.parent ?: Path.of(".")
        Files.createDirectories(parent)
        val temp = Files.createTempFile(parent, "${path.fileName}.", ".tmp")
        try {
            Files.writeString(temp, repository.encode())
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

    fun update(mutator: (SettingsRepository) -> Unit): SettingsRepository {
        val repository = load()
        mutator(repository)
        save(repository)
        return repository
    }
}
