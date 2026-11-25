package com.khm.snippets.core.io

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.Locale

/**
 * Every durable path of one library, relative to an injected [root]
 * (`SnippetStorageLocations` in `Snippet.swift`). On Apple platforms the root is
 * `Application Support/SnippetsClone`; on Android it is a folder in app-private storage
 * with the same layout below it.
 *
 * `snippets.json` is the only file directly in the root. Everything else lives in a
 * subfolder, and temporary files are staged in [tmpFolder], never beside their
 * destination.
 *
 * Not ported, because nothing on Android reads or writes them: `Usage/`, `AgentSkill/`,
 * `Sync/cksync-checkpoint.bin`, `Sync/library.lock` (see [LibraryGuard]),
 * `Sync/tombstones.json`, `Vault/audit.json`, and the iCloud-era `Sync/base.json` and
 * `Sync/journal.json`: a provider's files are in [ProtocolLocations].
 */
class StorageLocations(root: File) {

    val root: File = root.absoluteFile

    val snippetsFile: File = File(this.root, "snippets.json")

    /** Sync protocol state. `base.json` and `journal.json` below it are durable correctness state, not caches. */
    val syncFolder: File = File(this.root, "Sync")

    /** This device's own bookkeeping: device id, sticky halt, library generation. Shared by every provider. */
    val syncStateFile: File = File(syncFolder, "state.json")

    /**
     * Evidence that an unreadable primary library was deliberately moved out of the data
     * path. Kept apart from `state.json` so that losing that file cannot make a
     * quarantined library look like a first launch.
     */
    val libraryQuarantineMarkerFile: File = File(syncFolder, "library-quarantine")

    /** The provider-switch transaction, outside either provider's folder so startup finds it first. */
    val syncProviderSwitchFile: File = File(syncFolder, "provider-switch.json")

    /** The last envelope projected into the local library files: clocks, origins and extension data. */
    val syncLibraryMetadataFile: File = File(syncFolder, "library-metadata.json")

    /** Remote records that could not be decrypted. Kept for diagnosis, never applied. */
    val syncQuarantineFolder: File = File(syncFolder, "Quarantine")

    /** Parent of every provider's [ProtocolLocations.folder]. */
    val syncProvidersFolder: File = File(syncFolder, "Providers")

    /** Secure snippets. Metadata is plaintext there; content never is. */
    val vaultFolder: File = File(this.root, "Vault")

    val vaultFile: File = File(vaultFolder, "vault.json")

    val diagnosticsFolder: File = File(this.root, "Diagnostics")

    val diagnosticsLogsFolder: File = File(diagnosticsFolder, "Logs")

    /** Snapshots taken before anything destructive. */
    val backupsFolder: File = File(this.root, "Backups")

    /** Staging for [AtomicFileWriter]; on the same filesystem as every destination. */
    val tmpFolder: File = File(this.root, "Tmp")

    /** The lock every reader-modifier-writer of this root must hold. */
    val guard: LibraryGuard
        get() = LibraryGuard.forRoot(root)

    /** Every folder [createAllDirectories] creates, the root first. */
    val folders: List<File> = listOf(
        this.root, syncFolder, syncQuarantineFolder, syncProvidersFolder, vaultFolder,
        diagnosticsFolder, diagnosticsLogsFolder, backupsFolder, tmpFolder,
    )

    /**
     * Creates every folder. Failures are ignored, as in Swift: the first write into a
     * folder that could not be created reports the problem.
     */
    fun createAllDirectories() {
        for (folder in folders) {
            try {
                Files.createDirectories(folder.toPath())
            } catch (_: IOException) {
            }
        }
    }

    /**
     * `SyncProtocolLocations.http(opaqueProviderKey:)`: the files of one sync provider,
     * in a folder of their own so one provider's cursor, generations and pending journal
     * can never be read as another's.
     *
     * @return `null` unless the key is exactly 32 hex digits; it is lowercased first.
     */
    fun protocolLocations(opaqueProviderKey: String): ProtocolLocations? {
        val key = opaqueProviderKey.lowercase(Locale.ROOT)
        if (key.length != 32 || !key.all { it in '0'..'9' || it in 'a'..'f' }) return null
        return ProtocolLocations("http-$key", File(syncProvidersFolder, key))
    }
}

/** Every durable file owned by one sync provider (`SyncProtocolLocations`). */
class ProtocolLocations internal constructor(
    val identifier: String,
    val folder: File,
) {
    /** The confirmed snapshot every three-way merge is resolved against. */
    val baseFile: File = File(folder, "base.json")

    /** Durable desired and offered sync state. */
    val journalFile: File = File(folder, "journal.json")

    val quarantineFolder: File = File(folder, "Quarantine")

    val switchReceiptFile: File = File(folder, "switch-receipt.json")

    /** Creates [folder] and [quarantineFolder], owner-only where the filesystem has POSIX modes. */
    @Throws(IOException::class)
    fun createDirectories() {
        for (directory in listOf(folder, quarantineFolder)) {
            val path = directory.toPath()
            Files.createDirectories(path)
            if (path.fileSystem.supportedFileAttributeViews().contains("posix")) {
                try {
                    Files.setPosixFilePermissions(path, AtomicFileWriter.posixPermissions(OWNER_ONLY_DIRECTORY))
                } catch (_: IOException) {
                    // Swift ignores this failure too.
                }
            }
        }
    }

    override fun equals(other: Any?): Boolean =
        other is ProtocolLocations && identifier == other.identifier && folder == other.folder

    override fun hashCode(): Int = 31 * identifier.hashCode() + folder.hashCode()

    private companion object {
        const val OWNER_ONLY_DIRECTORY = 448 // 0700
    }
}
