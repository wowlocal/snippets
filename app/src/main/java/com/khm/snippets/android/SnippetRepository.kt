package com.khm.snippets.android

import android.content.Context
import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.security.SecureRandom
import java.util.UUID

class SnippetRepository(context: Context) {
    private val store = EncryptedStore(context)
    private val bridge = CoreBridge()
    private val client = HttpSyncClient()
    private val mutex = Mutex()
    private var libraryJSON = "[]"
    private var baseJSON = "[]"
    private var remoteRecordsJSON = "[]"
    private var configuration = CloudConfiguration()
    private var keys = freshKeyBundle()
    private var deviceID = ""

    private val mutableState = MutableStateFlow(LibraryState())
    val state: StateFlow<LibraryState> = mutableState.asStateFlow()

    init {
        try {
            libraryJSON = store.read(LIBRARY) ?: "[]"
            baseJSON = store.read(BASE) ?: "[]"
            remoteRecordsJSON = store.read(REMOTE) ?: "[]"
            configuration = store.read(CONFIG)?.let(::cloudConfiguration) ?: CloudConfiguration()
            keys = store.read(KEYS)?.let(::keyBundle) ?: keys.also { store.write(KEYS, it.toJSON()) }
            deviceID = store.read(DEVICE_ID) ?: freshDeviceID().also {
                store.write(DEVICE_ID, it)
            }
            publish()
        } catch (_: Exception) {
            mutableState.value = LibraryState(errorCode = "local_store_unreadable")
        }
    }

    suspend fun save(snippet: SnippetItem) = mutate {
        libraryJSON = bridge.upsert(libraryJSON, snippet)
        store.write(LIBRARY, libraryJSON)
    }

    suspend fun delete(id: String) = mutate {
        libraryJSON = bridge.delete(libraryJSON, id)
        store.write(LIBRARY, libraryJSON)
    }

    suspend fun search(query: String): List<SnippetItem> = withContext(Dispatchers.Default) {
        parseLibrary(bridge.search(libraryJSON, query))
    }

    suspend fun configureCloud(serverURL: String, accessToken: String, spaceID: String) = mutate {
        val changedScope = configuration.serverURL != serverURL.trim().trimEnd('/') ||
            configuration.spaceID != spaceID.trim()
        configuration = configuration.copy(
            provider = SyncProvider.SNIPPETS_CLOUD,
            serverURL = serverURL.trim().trimEnd('/'),
            accessToken = accessToken.trim(),
            spaceID = spaceID.trim(),
            cursor = if (changedScope) null else configuration.cursor,
            scopeBinding = if (changedScope) null else configuration.scopeBinding,
            datasetGeneration = if (changedScope) null else configuration.datasetGeneration,
            feedEpoch = if (changedScope) null else configuration.feedEpoch)
        if (changedScope) remoteRecordsJSON = "[]"
        persistSyncState()
    }

    suspend fun useDeviceOnly() = mutate {
        configuration = configuration.copy(provider = SyncProvider.DEVICE)
        store.write(CONFIG, configuration.toJSON())
    }

    suspend fun importPortableKeyBundle(bundleJSON: String) = mutate {
        val imported = keyBundle(bundleJSON.trim())
        require(Base64.decode(imported.key, Base64.DEFAULT).size == 32)
        require(Base64.decode(imported.salt, Base64.DEFAULT).isNotEmpty())
        require(imported.scopeID == "sync-v1")
        keys = imported
        baseJSON = "[]"
        remoteRecordsJSON = "[]"
        configuration = configuration.copy(
            cursor = null, scopeBinding = null, datasetGeneration = null, feedEpoch = null)
        store.write(KEYS, keys.toJSON())
        persistSyncState()
    }

    suspend fun syncNow() {
        mutex.withLock {
            if (configuration.provider != SyncProvider.SNIPPETS_CLOUD) return
            mutableState.value = mutableState.value.copy(isBusy = true, errorCode = null)
            withContext(Dispatchers.IO) {
                try {
                    repeat(3) {
                        val pull = client.pull(configuration, remoteRecordsJSON)
                        remoteRecordsJSON = pull.records
                        configuration = configuration.copy(
                            cursor = pull.cursor,
                            scopeBinding = pull.scopeBinding,
                            datasetGeneration = pull.datasetGeneration,
                            feedEpoch = pull.feedEpoch)

                        val reconciliation = bridge.reconcile(
                            libraryJSON, baseJSON, remoteRecordsJSON, keys, deviceID)
                        libraryJSON = reconciliation.library
                        store.write(LIBRARY, libraryJSON)

                        if (reconciliation.offers == "[]") {
                            baseJSON = libraryJSON
                            remoteRecordsJSON = reconciliation.records
                            persistSyncState()
                            publish(
                                label = if (reconciliation.needsUserAttention)
                                    "Synced — review conflicts" else "Synced")
                            return@withContext
                        }

                        val pushed = client.push(
                            configuration, remoteRecordsJSON, reconciliation.offers)
                        remoteRecordsJSON = pushed.records
                        persistSyncState()
                    }
                    throw SyncFailure("sync_did_not_converge")
                } catch (error: SyncFailure) {
                    publish(errorCode = error.code)
                } catch (error: CoreFailure) {
                    publish(errorCode = error.code)
                } catch (_: Exception) {
                    publish(errorCode = "sync_failed")
                }
            }
        }
    }

    fun configuration(): CloudConfiguration = configuration

    private suspend fun mutate(operation: () -> Unit) {
        mutex.withLock {
            mutableState.value = mutableState.value.copy(isBusy = true, errorCode = null)
            try {
                withContext(Dispatchers.IO) { operation() }
                publish()
            } catch (error: CoreFailure) {
                publish(errorCode = error.code)
            } catch (_: Exception) {
                publish(errorCode = "operation_failed")
            }
        }
    }

    private fun persistSyncState() {
        store.write(BASE, baseJSON)
        store.write(REMOTE, remoteRecordsJSON)
        store.write(CONFIG, configuration.toJSON())
    }

    private fun publish(label: String? = null, errorCode: String? = null) {
        val snippets = runCatching { parseLibrary(libraryJSON) }.getOrDefault(emptyList())
        mutableState.value = LibraryState(
            snippets = snippets,
            provider = configuration.provider,
            syncLabel = label ?: when (configuration.provider) {
                SyncProvider.DEVICE -> "On device"
                SyncProvider.SNIPPETS_CLOUD -> "Snippets Cloud"
            },
            isBusy = false,
            errorCode = errorCode)
    }

    private fun freshKeyBundle(): KeyBundle {
        val random = SecureRandom()
        return KeyBundle(
            key = ByteArray(32).also(random::nextBytes).base64(),
            salt = ByteArray(32).also(random::nextBytes).base64())
    }

    private fun freshDeviceID(): String {
        val random = ByteArray(4).also(SecureRandom()::nextBytes)
        if (random.all { it == 0.toByte() }) random[3] = 1
        return random.joinToString("") { "%02x".format(it) }
    }

    private fun ByteArray.base64(): String = Base64.encodeToString(this, Base64.NO_WRAP)

    companion object {
        fun newSnippet() = SnippetItem(
            id = UUID.randomUUID().toString(), name = "", keyword = "", content = "",
            tags = emptyList(), isEnabled = true, isPinned = false)

        private const val LIBRARY = "library.enc"
        private const val BASE = "base.enc"
        private const val REMOTE = "remote.enc"
        private const val CONFIG = "config.enc"
        private const val KEYS = "keys.enc"
        private const val DEVICE_ID = "device-id.enc"
    }
}
