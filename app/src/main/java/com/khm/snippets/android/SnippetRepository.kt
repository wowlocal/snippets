package com.khm.snippets.android

import android.content.Context
import android.content.Intent
import android.util.Base64
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.security.SecureRandom
import java.time.Instant
import java.util.UUID

class SnippetRepository(
    context: Context,
    private val snippetsCloudEnabled: Boolean = BuildConfig.SNIPPETS_CLOUD_ENABLED,
) {
    private val store = EncryptedStore(context)
    private val bridge = CoreBridge()
    private val client = HttpSyncClient()
    private val authenticator = CloudAuthenticator(context, store)
    private val mutex = Mutex()
    private val recoveryScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var libraryJSON = "[]"
    private var baseJSON = "[]"
    private var remoteRecordsJSON = "[]"
    private var configuration = CloudConfiguration()
    private var keys: KeyBundle? = null
    private var keyBinding: CloudKeyBinding? = null
    private var deviceID = ""
    private var cloudKeyStatus = CloudKeyStatus.SIGNED_OUT
    private var pairingQRCode: String? = null
    private var pairingConfirmationCode: String? = null
    private var approvalConfirmationCode: String? = null
    private var pairingExpiresAtEpochSeconds: Long? = null
    private var recoveryKitVerified = false
    private var pendingLibrarySelection: PendingLibrarySelection? = null

    private val mutableState = MutableStateFlow(LibraryState(isBusy = true))
    val state: StateFlow<LibraryState> = mutableState.asStateFlow()
    private val initialization = CompletableDeferred<Unit>()
    @Volatile private var didInitialize = false
    @Volatile private var cloudSessionAvailable = false

    init {
        // The activity can compose its first, responsive frame while device-bound
        // files and AndroidKeyStore are opened on the I/O dispatcher. Every mutating
        // API awaits this one-shot barrier, so the loading frame can never overwrite
        // durable state with the temporary empty snapshot.
        recoveryScope.launch {
            var remoteLogoutPending = false
            try {
                if (store.read(PENDING_LOCAL_ERASE) != null) {
                    completePendingLocalErase()
                }
                libraryJSON = store.read(LIBRARY) ?: "[]"
                baseJSON = store.read(BASE) ?: "[]"
                remoteRecordsJSON = store.read(REMOTE) ?: "[]"
                configuration = store.read(CONFIG)?.let(::cloudConfiguration)
                    ?: CloudConfiguration()
                if (!snippetsCloudEnabled && configuration.provider == SyncProvider.SNIPPETS_CLOUD) {
                    // Preserve the durable development selection for a later opt-in build,
                    // but never let a shipping dark-launch build enter the HTTP data plane.
                    configuration = configuration.copy(provider = SyncProvider.DEVICE)
                }
                keys = store.read(KEYS)?.let(::keyBundle)
                keyBinding = store.read(KEY_BINDING)?.let(::cloudKeyBinding)
                pendingLibrarySelection = store.read(PENDING_SPACE_SELECTION)?.let { raw ->
                    runCatching { PendingLibrarySelection.fromJSON(raw) }
                        .onFailure { store.delete(PENDING_SPACE_SELECTION) }
                        .getOrNull()
                }
                recoveryKitVerified = store.read(RECOVERY_VERIFICATION_FILE)
                    ?.let(RecoveryKitVerification::fromJSON)
                    ?.matches(configuration) == true
                if (!recoveryKitVerified) invalidateRecoveryVerification(store)
                deviceID = store.read(DEVICE_ID) ?: freshDeviceID().also {
                    store.write(DEVICE_ID, it)
                }
                cloudSessionAvailable = authenticator.hasSession(
                    pendingLibrarySelection?.serverURL
                        ?: configuration.serverURL.takeIf(String::isNotBlank))
                if (!cloudSessionAvailable && pendingLibrarySelection != null) {
                    store.delete(PENDING_SPACE_SELECTION)
                    pendingLibrarySelection = null
                }
                cloudKeyStatus = when {
                    !cloudSessionAvailable -> CloudKeyStatus.SIGNED_OUT
                    hasBoundKey() -> CloudKeyStatus.READY
                    else -> CloudKeyStatus.NEEDS_TRUSTED_DEVICE_OR_RECOVERY
                }
                store.read(PENDING_PAIRING)?.let { raw ->
                    runCatching { LibraryKeyBootstrap.PendingPairing.fromJSON(raw) }
                        .onSuccess { pending ->
                            pairingQRCode = pending.invitation.toQRPayload()
                            pairingConfirmationCode = pending.invitation.confirmationCode
                            pairingExpiresAtEpochSeconds = pending.invitation.expiresAtEpochSeconds
                            cloudKeyStatus = CloudKeyStatus.WAITING_FOR_APPROVAL
                        }
                        .onFailure { store.delete(PENDING_PAIRING) }
                }
                store.read(PENDING_APPROVAL)?.let { raw ->
                    runCatching { LibraryKeyBootstrap.PairingInvitation.fromQRPayload(raw) }
                        .onSuccess { invitation ->
                            approvalConfirmationCode = invitation.confirmationCode
                            cloudKeyStatus = CloudKeyStatus.APPROVAL_READY
                        }
                        .onFailure { store.delete(PENDING_APPROVAL) }
                }
                store.read(RECOVERY_PRESENTATION)?.let { payload ->
                    runCatching { LibraryKeyBootstrap.RecoveryKit.fromQRPayload(payload) }
                        .onSuccess { kit ->
                            if (kit.serverURL == configuration.serverURL &&
                                kit.spaceID.equals(configuration.spaceID, ignoreCase = true)) {
                                // Validate the durable value, but do not publish either
                                // secret until this new process gets local user presence.
                                cloudKeyStatus = CloudKeyStatus.RECOVERY_KIT_LOCKED
                            } else {
                                store.delete(RECOVERY_PRESENTATION)
                            }
                        }
                        .onFailure { store.delete(RECOVERY_PRESENTATION) }
                }
                if (store.read(PENDING_RECOVERY) != null &&
                    cloudKeyStatus != CloudKeyStatus.RECOVERY_KIT_LOCKED) {
                    cloudKeyStatus = CloudKeyStatus.RECOVERY_AUTH_REQUIRED
                }
                remoteLogoutPending = authenticator.hasPendingRevocation()
                if (remoteLogoutPending) {
                    // Keep the root only long enough to retry remote revocation; never let
                    // an interrupted logout re-enter the cloud data plane.
                    configuration = configuration.copy(provider = SyncProvider.DEVICE)
                    cloudKeyStatus = CloudKeyStatus.SIGNED_OUT
                    cloudSessionAvailable = false
                }
                didInitialize = true
                publish()
            } catch (_: Exception) {
                didInitialize = true
                mutableState.value = LibraryState(errorCode = "local_store_unreadable")
            } finally {
                initialization.complete(Unit)
            }
            if (remoteLogoutPending) disconnectCloudAccount()
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

    suspend fun search(query: String): List<SnippetItem> {
        initialization.await()
        return withContext(Dispatchers.Default) {
            parseLibrary(bridge.search(libraryJSON, query))
        }
    }

    suspend fun configureCloud(serverURL: String, accessToken: String, spaceID: String) = mutate {
        requireCloudFeature()
        val normalizedServerURL = serverURL.trim().trimEnd('/')
        val normalizedAccessToken = accessToken.trim()
        val resolution = client.resolveSpace(normalizedServerURL, spaceID.trim(), normalizedAccessToken)
        val changedScope = configuration.serverURL != normalizedServerURL ||
            !configuration.spaceID.equals(resolution.spaceID, ignoreCase = true) ||
            !configuration.serverInstanceID.equals(resolution.serverInstanceID, ignoreCase = true)
        configuration = configuration.copy(
            provider = SyncProvider.SNIPPETS_CLOUD,
            serverURL = normalizedServerURL,
            apiBaseURL = normalizedServerURL + "/v2",
            protocolMajor = 2,
            accessToken = normalizedAccessToken,
            spaceID = resolution.spaceID,
            serverInstanceID = resolution.serverInstanceID,
            cursor = if (changedScope) null else configuration.cursor,
            scopeBinding = if (changedScope) null else configuration.scopeBinding,
            datasetGeneration = if (changedScope) null else configuration.datasetGeneration,
            feedEpoch = if (changedScope) null else configuration.feedEpoch,
            lastSuccessfulSyncEpochSeconds = if (changedScope) null
                else configuration.lastSuccessfulSyncEpochSeconds)
        if (changedScope) {
            remoteRecordsJSON = "[]"
            clearBootstrapState()
            invalidateRecoveryVerification(store)
            recoveryKitVerified = false
        }
        if (keys == null) keys = freshKeyBundle().also { store.write(KEYS, it.toJSON()) }
        bindCurrentKey(normalizedServerURL, resolution.spaceID)
        cloudKeyStatus = CloudKeyStatus.READY
        persistSyncState()
    }

    suspend fun beginCloudSignIn(
        serverURL: String,
        stepUp: Boolean = false,
        chooseAccount: Boolean = false,
    ): Intent? {
        initialization.await()
        if (!snippetsCloudEnabled) return null
        return mutex.withLock {
            mutableState.value = mutableState.value.copy(isBusy = true, errorCode = null)
            try {
                val intent = withContext(Dispatchers.IO) {
                    if (store.read(PENDING_LOCAL_ERASE) != null) {
                        completePendingLocalErase()
                    }
                    authenticator.authorizationIntent(serverURL, stepUp, chooseAccount)
                }
                publish()
                intent
            } catch (error: CloudAuthFailure) {
                publish(errorCode = error.code)
                null
            } catch (_: Exception) {
                publish(errorCode = "sign_in_failed")
                null
            }
        }
    }

    internal suspend fun completeCloudSignIn(result: Intent?): CloudSignInCompletion {
        initialization.await()
        if (!snippetsCloudEnabled) return CloudSignInCompletion(succeeded = false)
        return mutex.withLock {
            mutableState.value = mutableState.value.copy(isBusy = true, errorCode = null)
            try {
                val completion = withContext(Dispatchers.IO) {
                    val authorization = authenticator.completeAuthorization(result)
                    cloudSessionAvailable = true
                    val existingSpace = configuration.takeIf {
                        it.serverURL == authorization.serverURL
                    }?.spaceID?.takeIf(String::isNotBlank)
                    val candidates = client.personalSpaceCandidates(
                        authorization.serverURL,
                        authorization.accessToken,
                    )
                    val resolution = automaticPersonalSpace(candidates, existingSpace)
                        ?: if (candidates.isEmpty()) {
                            client.createPersonalSpace(
                                authorization.serverURL,
                                authorization.accessToken,
                            )
                        } else {
                            val pending = PendingLibrarySelection(
                                serverURL = authorization.serverURL,
                                choices = candidates.map {
                                    CloudLibraryChoice(
                                        spaceID = it.spaceID,
                                        serverInstanceID = it.serverInstanceID,
                                        role = it.role,
                                    )
                                },
                                previousLibraryID = if (authorization.accountChange) {
                                    libraryID()
                                } else {
                                    null
                                },
                            )
                            store.write(PENDING_SPACE_SELECTION, pending.toJSON())
                            pendingLibrarySelection = pending
                            return@withContext PostAuthorizationCompletion(
                                recoveryKit = null,
                                needsLibrarySelection = true,
                            )
                        }
                    if (authorization.accountChange && (
                            configuration.serverURL != authorization.serverURL ||
                                !configuration.spaceID.equals(
                                    resolution.spaceID,
                                    ignoreCase = true,
                                ) ||
                                !configuration.serverInstanceID.equals(
                                    resolution.serverInstanceID,
                                    ignoreCase = true,
                                )
                            )) {
                        val choice = candidates.firstOrNull {
                            it.spaceID.equals(resolution.spaceID, ignoreCase = true)
                        }?.let {
                            CloudLibraryChoice(it.spaceID, it.serverInstanceID, it.role)
                        } ?: CloudLibraryChoice(
                            resolution.spaceID,
                            resolution.serverInstanceID,
                            "owner",
                        )
                        val pending = PendingLibrarySelection(
                            serverURL = authorization.serverURL,
                            choices = listOf(choice),
                            previousLibraryID = libraryID(),
                        )
                        store.write(PENDING_SPACE_SELECTION, pending.toJSON())
                        pendingLibrarySelection = pending
                        return@withContext PostAuthorizationCompletion(
                            recoveryKit = null,
                            needsLibrarySelection = true,
                        )
                    }
                    PostAuthorizationCompletion(
                        recoveryKit = completeResolvedAuthorization(
                            authorization.serverURL,
                            authorization.accessToken,
                            resolution,
                        ),
                        needsLibrarySelection = false,
                    )
                }
                if (completion.needsLibrarySelection) {
                    publish(errorCode = "space_selection_required")
                    CloudSignInCompletion(succeeded = false)
                } else {
                    publish(label = "Account connected")
                    CloudSignInCompletion(
                        succeeded = true,
                        recoveryKit = completion.recoveryKit,
                    )
                }
            } catch (error: CloudAuthFailure) {
                publish(errorCode = error.code)
                CloudSignInCompletion(succeeded = false)
            } catch (error: SyncFailure) {
                publish(errorCode = error.code)
                CloudSignInCompletion(succeeded = false)
            } catch (_: Exception) {
                publish(errorCode = "sign_in_failed")
                CloudSignInCompletion(succeeded = false)
            }
        }
    }

    internal suspend fun selectCloudLibrary(spaceID: String): CloudSignInCompletion {
        initialization.await()
        if (!snippetsCloudEnabled) return CloudSignInCompletion(succeeded = false)
        return mutex.withLock {
            mutableState.value = mutableState.value.copy(isBusy = true, errorCode = null)
            try {
                val recoveryKit = withContext(Dispatchers.IO) {
                    val pending = requireNotNull(pendingLibrarySelection)
                    val selected = pending.choices.singleOrNull {
                        it.spaceID.equals(spaceID, ignoreCase = true)
                    } ?: throw SyncFailure("space_selection_required")
                    val token = authenticator.freshAccessToken(pending.serverURL)
                    val verified = client.resolveSpace(
                        pending.serverURL,
                        selected.spaceID,
                        token,
                    )
                    if (!verified.serverInstanceID.equals(
                            selected.serverInstanceID,
                            ignoreCase = true,
                        )) {
                        throw SyncFailure("scope_review_required")
                    }
                    completeResolvedAuthorization(
                        pending.serverURL,
                        token,
                        verified,
                    )
                }
                publish(label = "Account connected")
                CloudSignInCompletion(succeeded = true, recoveryKit = recoveryKit)
            } catch (error: CloudAuthFailure) {
                publish(errorCode = error.code)
                CloudSignInCompletion(succeeded = false)
            } catch (error: SyncFailure) {
                publish(errorCode = error.code)
                CloudSignInCompletion(succeeded = false)
            } catch (_: Exception) {
                publish(errorCode = "sign_in_failed")
                CloudSignInCompletion(succeeded = false)
            }
        }
    }

    private fun completeResolvedAuthorization(
        serverURL: String,
        accessToken: String,
        resolution: HttpSyncClient.SpaceResolution,
    ): RecoveryKitPresentation? {
        val changedScope = configuration.serverURL != serverURL ||
            !configuration.spaceID.equals(resolution.spaceID, ignoreCase = true) ||
            !configuration.serverInstanceID.equals(
                resolution.serverInstanceID,
                ignoreCase = true,
            )
        configuration = configuration.copy(
            provider = configuration.provider,
            serverURL = serverURL,
            apiBaseURL = serverURL + "/v2",
            protocolMajor = 2,
            accessToken = "",
            spaceID = resolution.spaceID,
            serverInstanceID = resolution.serverInstanceID,
            cursor = if (changedScope) null else configuration.cursor,
            scopeBinding = if (changedScope) null else configuration.scopeBinding,
            datasetGeneration = if (changedScope) null else configuration.datasetGeneration,
            feedEpoch = if (changedScope) null else configuration.feedEpoch,
            lastSuccessfulSyncEpochSeconds = if (changedScope) null
                else configuration.lastSuccessfulSyncEpochSeconds,
        )
        if (changedScope) {
            remoteRecordsJSON = "[]"
            clearBootstrapState()
            invalidateRecoveryVerification(store)
            recoveryKitVerified = false
        } else {
            store.delete(PENDING_SPACE_SELECTION)
            pendingLibrarySelection = null
        }
        val presentation = finishPostAuthorization(accessToken)
        persistSyncState()
        return presentation
    }

    suspend fun disconnectCloudAccount() = mutate {
        if (store.read(PENDING_LOCAL_ERASE) == null) {
            if (disconnectBlockedForRecovery(cloudKeyStatus)) {
                throw SyncFailure("recovery_kit_not_saved")
            }
            authenticator.revokeCurrentSession()
            // This marker is the commit point between confirmed remote revocation and
            // local deletion. It is encrypted and fsync/rename durable.
            store.write(PENDING_LOCAL_ERASE, "pending")
        }
        // Disable the cloud data plane immediately in memory, even if a later local
        // deletion fails and this process remains alive.
        keys = null
        keyBinding = null
        configuration = CloudConfiguration(provider = SyncProvider.DEVICE)
        cloudKeyStatus = CloudKeyStatus.SIGNED_OUT
        recoveryKitVerified = false
        completePendingLocalErase()
    }

    fun isCloudSignedIn(): Boolean =
        snippetsCloudEnabled && didInitialize && cloudSessionAvailable &&
            pendingLibrarySelection == null &&
            configuration.serverURL.isNotBlank() && cloudKeyStatus != CloudKeyStatus.SIGNED_OUT

    suspend fun useDeviceOnly() = mutate {
        configuration = configuration.copy(provider = SyncProvider.DEVICE)
        store.write(CONFIG, configuration.toJSON())
    }

    suspend fun useSnippetsCloud() = mutate {
        requireCloudFeature()
        if (store.read(PENDING_LOCAL_ERASE) != null || authenticator.hasPendingRevocation() ||
            pendingLibrarySelection != null ||
            configuration.serverURL.isBlank() || configuration.spaceID.isBlank() ||
            (configuration.accessToken.isBlank() && !authenticator.hasSession(configuration.serverURL))) {
            throw CloudAuthFailure("sign_in_required")
        }
        if (!hasBoundKey()) throw SyncFailure("library_key_required")
        if (configuration.requiresServerInstanceReview()) {
            throw SyncFailure("scope_review_required")
        }
        configuration = configuration.copy(provider = SyncProvider.SNIPPETS_CLOUD)
        store.write(CONFIG, configuration.toJSON())
    }

    suspend fun importPortableKeyBundle(bundleJSON: String) = mutate {
        val imported = keyBundle(bundleJSON.trim())
        require(Base64.decode(imported.key, Base64.DEFAULT).size == 32)
        require(Base64.decode(imported.salt, Base64.DEFAULT).size == 32)
        require(imported.scopeID == "sync-v1")
        keys = imported
        if (snippetsCloudEnabled &&
            configuration.serverURL.isNotBlank() && configuration.spaceID.isNotBlank() &&
            !configuration.requiresServerInstanceReview()) {
            bindCurrentKey(configuration.serverURL, configuration.spaceID)
            configuration = configuration.copy(provider = SyncProvider.SNIPPETS_CLOUD)
            cloudKeyStatus = CloudKeyStatus.READY
        }
        baseJSON = "[]"
        remoteRecordsJSON = "[]"
        configuration = configuration.copy(
            cursor = null,
            scopeBinding = null,
            datasetGeneration = null,
            feedEpoch = null,
            lastSuccessfulSyncEpochSeconds = null)
        store.write(KEYS, imported.toJSON())
        persistSyncState()
    }

    /** Starts a five-minute recipient invitation. Its private key is device-only. */
    suspend fun beginDevicePairing() = bootstrap {
        requireSignedInCoordinates()
        val token = freshPinnedAccessToken()
        val draft = LibraryKeyBootstrap.createPairingDraft()
        val created = client.createPairing(
            configuration.serverURL,
            configuration.spaceID,
            token,
            draft,
            requireServerInstanceID(),
        )
        validatePairing(
            created,
            created.pairingID,
            draft.recipientPublicKey,
            draft.nonce,
        )
        require(created.state == "pending")
        require(created.algorithm == null && created.ciphertext == null)
        val invitation = LibraryKeyBootstrap.PairingInvitation(
            serverURL = configuration.serverURL,
            spaceID = configuration.spaceID.lowercase(),
            pairingID = created.pairingID,
            nonce = created.nonce,
            recipientPublicKey = created.recipientPublicKey,
            expiresAtEpochSeconds = created.expiresAtEpochSeconds,
        )
        require(created.authenticationTag == invitation.confirmationCode)
        val pending = LibraryKeyBootstrap.PendingPairing(draft, invitation)
        store.write(PENDING_PAIRING, pending.toJSON())
        pairingQRCode = invitation.toQRPayload()
        pairingConfirmationCode = invitation.confirmationCode
        pairingExpiresAtEpochSeconds = invitation.expiresAtEpochSeconds
        cloudKeyStatus = CloudKeyStatus.WAITING_FOR_APPROVAL
    }

    /** Polls once; an approved envelope is returned-and-deleted atomically. */
    suspend fun checkDevicePairing() = bootstrap {
        val pending = pendingPairing()
        val token = freshPinnedAccessToken()
        val status = client.pairing(
            configuration.serverURL,
            configuration.spaceID,
            pending.invitation.pairingID,
            token,
            requireServerInstanceID(),
        )
        validatePairing(
            status,
            pending.invitation.pairingID,
            pending.draft.recipientPublicKey,
            pending.draft.nonce,
            pending.invitation.expiresAtEpochSeconds,
        )
        require(status.authenticationTag == pending.invitation.confirmationCode)
        require(status.algorithm == null && status.ciphertext == null)
        if (status.state == "pending") {
            cloudKeyStatus = CloudKeyStatus.WAITING_FOR_APPROVAL
            return@bootstrap
        }
        val taken = client.takeApprovedPairing(
            configuration.serverURL,
            configuration.spaceID,
            pending.invitation.pairingID,
            token,
            status,
            requireServerInstanceID(),
        )
        validatePairing(
            taken,
            pending.invitation.pairingID,
            pending.draft.recipientPublicKey,
            pending.draft.nonce,
            pending.invitation.expiresAtEpochSeconds,
        )
        require(taken.authenticationTag == pending.invitation.confirmationCode)
        require(taken.state == "approved")
        require(taken.algorithm == LibraryKeyBootstrap.PAIRING_ALGORITHM)
        val ciphertext = requireNotNull(taken.ciphertext)
        val bundle = LibraryKeyBootstrap.openPairedEnvelope(pending, ciphertext)
        installCloudKey(bundle)
        store.delete(PENDING_PAIRING)
        pairingQRCode = null
        pairingConfirmationCode = null
        pairingExpiresAtEpochSeconds = null
        cloudKeyStatus = CloudKeyStatus.READY
    }

    suspend fun cancelDevicePairing() = bootstrap {
        val pending = pendingPairing()
        val token = freshPinnedAccessToken()
        runCatching {
            client.cancelPairing(
                configuration.serverURL,
                configuration.spaceID,
                pending.invitation.pairingID,
                token,
            )
        }
        store.delete(PENDING_PAIRING)
        pairingQRCode = null
        pairingConfirmationCode = null
        pairingExpiresAtEpochSeconds = null
        cloudKeyStatus = CloudKeyStatus.NEEDS_TRUSTED_DEVICE_OR_RECOVERY
    }

    /** Validates a scanned QR against the server before any approval is offered. */
    suspend fun preparePairingApproval(qrPayload: String) = bootstrap {
        require(hasBoundKey())
        val invitation = LibraryKeyBootstrap.PairingInvitation.fromQRPayload(qrPayload.trim())
        require(invitation.serverURL == configuration.serverURL)
        require(invitation.spaceID.equals(configuration.spaceID, ignoreCase = true))
        val token = freshPinnedAccessToken()
        val serverPairing = client.pairing(
            invitation.serverURL,
            invitation.spaceID,
            invitation.pairingID,
            token,
            requireServerInstanceID(),
        )
        validatePairing(
            serverPairing,
            invitation.pairingID,
            invitation.recipientPublicKey,
            invitation.nonce,
            invitation.expiresAtEpochSeconds,
        )
        require(serverPairing.authenticationTag == invitation.confirmationCode)
        require(serverPairing.algorithm == null && serverPairing.ciphertext == null)
        if (serverPairing.state == "approved") {
            // Recover an approval whose success response was lost. Only the recipient
            // can atomically take the redacted envelope from the consume endpoint.
            store.delete(PENDING_APPROVAL)
            approvalConfirmationCode = null
            cloudKeyStatus = CloudKeyStatus.READY
            return@bootstrap
        }
        require(serverPairing.state == "pending")
        require(serverPairing.expiresAtEpochSeconds == invitation.expiresAtEpochSeconds)
        store.write(PENDING_APPROVAL, invitation.toQRPayload())
        approvalConfirmationCode = invitation.confirmationCode
        cloudKeyStatus = CloudKeyStatus.APPROVAL_READY
    }

    fun hasPendingPairingApproval(): Boolean =
        didInitialize && approvalConfirmationCode != null

    suspend fun cancelPairingApproval() = bootstrap {
        store.delete(PENDING_APPROVAL)
        approvalConfirmationCode = null
        cloudKeyStatus = if (hasBoundKey()) CloudKeyStatus.READY
        else CloudKeyStatus.NEEDS_TRUSTED_DEVICE_OR_RECOVERY
    }

    suspend fun restoreWithRecoveryKit(qrOrLongCode: String) = bootstrap {
        requireSignedInCoordinates()
        val token = freshPinnedAccessToken()
        val state = client.recoveryEnvelope(
            configuration.serverURL,
            configuration.spaceID,
            token,
            requireServerInstanceID(),
        )
        val recovery = requireNotNull(state.recovery)
        require(recovery.algorithm == LibraryKeyBootstrap.RECOVERY_ALGORITHM)
        val value = qrOrLongCode.trim()
        val kit = if (value.startsWith("{")) {
            LibraryKeyBootstrap.RecoveryKit.fromQRPayload(value)
        } else {
            LibraryKeyBootstrap.RecoveryKit.fromLongCode(
                value,
                configuration.serverURL,
                configuration.spaceID,
                recovery.keyEpoch,
            )
        }
        require(kit.serverURL == configuration.serverURL)
        require(kit.spaceID.equals(configuration.spaceID, ignoreCase = true))
        require(kit.keyEpoch == recovery.keyEpoch && kit.keyEpoch == state.keyEpoch)
        val bundle = LibraryKeyBootstrap.openRecoveryEnvelope(kit, recovery.ciphertext)
        installCloudKey(bundle)
        cloudKeyStatus = CloudKeyStatus.READY
    }

    /** Prepares a replacement kit; UI must require local biometrics then OIDC step-up. */
    suspend fun prepareRecoveryKitReplacement() = bootstrap {
        require(hasBoundKey())
        // This durable reset is the first step of replacement. Once a new envelope
        // can be published, the prior verification must never authorize logout after
        // a process restart, even if setup is interrupted before the new kit is shown.
        invalidateRecoveryVerification(store)
        recoveryKitVerified = false
        val token = freshPinnedAccessToken()
        val current = client.recoveryEnvelope(
            configuration.serverURL,
            configuration.spaceID,
            token,
            requireServerInstanceID(),
        )
        val recovery = LibraryKeyBootstrap.createRecoveryEnvelope(
            requireNotNull(keys).toJSON(),
            configuration.serverURL,
            configuration.spaceID,
            current.keyEpoch,
        )
        store.write(
            PENDING_RECOVERY,
            PendingRecoveryUpload(
                kitPayload = recovery.kit.toQRPayload(),
                ciphertext = recovery.ciphertext,
                expectedVersion = current.recovery?.version,
                newLibraryBundleJSON = null,
            ).toJSON(),
        )
        cloudKeyStatus = CloudKeyStatus.RECOVERY_AUTH_REQUIRED
    }

    suspend fun acknowledgeRecoveryKitSaved() = bootstrap {
        val presentation = requireNotNull(store.read(RECOVERY_PRESENTATION))
        val kit = LibraryKeyBootstrap.RecoveryKit.fromQRPayload(presentation)
        require(kit.serverURL == configuration.serverURL)
        require(kit.spaceID.equals(configuration.spaceID, ignoreCase = true))
        store.write(
            RECOVERY_VERIFICATION_FILE,
            RecoveryKitVerification.fromRecoveryKit(kit).toJSON(),
        )
        store.delete(RECOVERY_PRESENTATION)
        store.delete(PENDING_RECOVERY)
        recoveryKitVerified = true
        cloudKeyStatus = CloudKeyStatus.READY
    }

    /**
     * Called only after BiometricPrompt succeeds. The secret is returned once to the
     * current Settings composition and is never retained in the process-wide StateFlow.
     */
    internal suspend fun revealPendingRecoveryKit(): RecoveryKitPresentation? {
        initialization.await()
        if (!snippetsCloudEnabled) return null
        return mutex.withLock {
            mutableState.value = mutableState.value.copy(isBusy = true, errorCode = null)
            try {
                val presentation = withContext(Dispatchers.IO) {
                    requireSignedInCoordinates()
                    val payload = requireNotNull(store.read(RECOVERY_PRESENTATION))
                    val kit = LibraryKeyBootstrap.RecoveryKit.fromQRPayload(payload)
                    require(kit.serverURL == configuration.serverURL)
                    require(kit.spaceID.equals(configuration.spaceID, ignoreCase = true))
                    RecoveryKitPresentation(payload, kit.longCode)
                }
                publish()
                presentation
            } catch (error: CloudAuthFailure) {
                publish(errorCode = error.code)
                null
            } catch (error: SyncFailure) {
                publish(errorCode = error.code)
                null
            } catch (_: Exception) {
                publish(errorCode = "secure_setup_failed")
                null
            }
        }
    }

    suspend fun syncNow(): Boolean {
        initialization.await()
        return mutex.withLock {
            if (!snippetsCloudEnabled || store.read(PENDING_LOCAL_ERASE) != null ||
                authenticator.hasPendingRevocation() ||
                pendingLibrarySelection != null ||
                configuration.provider != SyncProvider.SNIPPETS_CLOUD) return@withLock false
            if (!hasBoundKey()) {
                publish(errorCode = "library_key_required")
                return@withLock false
            }
            mutableState.value = mutableState.value.copy(
                isBusy = true,
                errorCode = null,
                syncLabel = "Syncing your library…",
                setupStage = CloudSetupStage.SYNCING,
            )
            var succeeded = false
            withContext(Dispatchers.IO) {
                try {
                    val manualAccessToken = configuration.accessToken.takeIf(String::isNotBlank)
                    var accessToken = manualAccessToken
                        ?: authenticator.freshAccessToken(configuration.serverURL)
                    var forcedRefreshAttempted = false
                    while (true) {
                        try {
                            syncWithAccessToken(accessToken)
                            succeeded = true
                            return@withContext
                        } catch (error: SyncFailure) {
                            if (manualAccessToken == null &&
                                !forcedRefreshAttempted &&
                                error.code == "authentication_required") {
                                forcedRefreshAttempted = true
                                accessToken = authenticator.freshAccessToken(
                                    configuration.serverURL,
                                    forceRefresh = true,
                                )
                                continue
                            }
                            throw error
                        }
                    }
                } catch (error: SyncFailure) {
                    publish(errorCode = error.code)
                } catch (error: CloudAuthFailure) {
                    publish(errorCode = error.code)
                } catch (error: CoreFailure) {
                    publish(errorCode = error.code)
                } catch (_: Exception) {
                    publish(errorCode = "sync_failed")
                }
            }
            succeeded
        }
    }

    private fun syncWithAccessToken(accessToken: String) {
        repeat(3) {
            val pull = client.pull(configuration, remoteRecordsJSON, accessToken)
            remoteRecordsJSON = pull.records
            configuration = configuration.copy(
                cursor = pull.cursor,
                serverInstanceID = pull.serverInstanceID,
                scopeBinding = pull.scopeBinding,
                datasetGeneration = pull.datasetGeneration,
                feedEpoch = pull.feedEpoch)

            val reconciliation = bridge.reconcile(
                libraryJSON,
                baseJSON,
                remoteRecordsJSON,
                keys ?: throw SyncFailure("library_key_required"),
                deviceID)
            libraryJSON = reconciliation.library
            store.write(LIBRARY, libraryJSON)

            if (reconciliation.offers == "[]") {
                baseJSON = libraryJSON
                remoteRecordsJSON = reconciliation.records
                configuration = configuration.copy(
                    lastSuccessfulSyncEpochSeconds = Instant.now().epochSecond,
                )
                persistSyncState()
                publish(
                    label = if (reconciliation.needsUserAttention)
                        "Up to date — review conflicts" else "Up to date")
                return
            }

            val pushed = client.push(
                configuration, remoteRecordsJSON, reconciliation.offers, accessToken)
            remoteRecordsJSON = pushed.records
            persistSyncState()
        }
        throw SyncFailure("sync_did_not_converge")
    }

    fun configuration(): CloudConfiguration =
        if (didInitialize) configuration else CloudConfiguration()

    private suspend fun bootstrap(operation: suspend () -> Unit) {
        initialization.await()
        mutex.withLock {
            mutableState.value = mutableState.value.copy(isBusy = true, errorCode = null)
            try {
                requireCloudFeature()
                withContext(Dispatchers.IO) { operation() }
                persistSyncState()
                publish()
            } catch (error: CloudAuthFailure) {
                publish(errorCode = error.code)
            } catch (error: SyncFailure) {
                publish(errorCode = error.code)
            } catch (_: Exception) {
                publish(errorCode = "secure_setup_failed")
            }
        }
    }

    private fun requireCloudFeature() {
        if (!snippetsCloudEnabled) throw CloudAuthFailure("cloud_feature_disabled")
    }

    private fun finishPostAuthorization(accessToken: String): RecoveryKitPresentation? {
        store.read(PENDING_APPROVAL)?.let { raw ->
            finishPendingApproval(raw, accessToken)
            return null
        }
        store.read(PENDING_RECOVERY)?.let { raw ->
            val pending = PendingRecoveryUpload.fromJSON(raw)
            try {
                return finishPendingRecovery(pending, accessToken)
            } catch (failure: SyncFailure) {
                if (failure.code != "conflict") throw failure
                store.delete(PENDING_RECOVERY)
                cloudKeyStatus = if (pending.newLibraryBundleJSON == null && hasBoundKey()) {
                    CloudKeyStatus.READY
                } else {
                    configuration = configuration.copy(provider = SyncProvider.DEVICE)
                    CloudKeyStatus.NEEDS_TRUSTED_DEVICE_OR_RECOVERY
                }
                return null
            }
        }

        if (hasBoundKey()) {
            configuration = configuration.copy(provider = SyncProvider.SNIPPETS_CLOUD)
            cloudKeyStatus = CloudKeyStatus.READY
            return null
        }

        val envelope = client.recoveryEnvelope(
            configuration.serverURL,
            configuration.spaceID,
            accessToken,
            requireServerInstanceID(),
        )
        val hasRemoteRecords = client.hasRemoteRecords(
            configuration.serverURL,
            configuration.spaceID,
            accessToken,
            requireServerInstanceID(),
        )
        if (envelope.recovery != null || hasRemoteRecords) {
            configuration = configuration.copy(provider = SyncProvider.DEVICE)
            cloudKeyStatus = CloudKeyStatus.NEEDS_TRUSTED_DEVICE_OR_RECOVERY
            return null
        }

        // A truly empty personal space is the only state in which this device may
        // author a root key without pairing. It remains provisional until its nil-CAS
        // recovery envelope wins, closing the two-new-devices mint race.
        val provisionalBundle = freshKeyBundle()
        val recovery = LibraryKeyBootstrap.createRecoveryEnvelope(
            provisionalBundle.toJSON(),
            configuration.serverURL,
            configuration.spaceID,
            envelope.keyEpoch,
        )
        val pending = PendingRecoveryUpload(
            kitPayload = recovery.kit.toQRPayload(),
            ciphertext = recovery.ciphertext,
            expectedVersion = null,
            newLibraryBundleJSON = provisionalBundle.toJSON(),
        )
        store.write(PENDING_RECOVERY, pending.toJSON())
        return try {
            finishPendingRecovery(pending, accessToken)
        } catch (failure: SyncFailure) {
            if (failure.code == "conflict") {
                store.delete(PENDING_RECOVERY)
                configuration = configuration.copy(provider = SyncProvider.DEVICE)
                cloudKeyStatus = CloudKeyStatus.NEEDS_TRUSTED_DEVICE_OR_RECOVERY
                return null
            }
            if (failure.code != "reauthentication_required") throw failure
            configuration = configuration.copy(provider = SyncProvider.DEVICE)
            cloudKeyStatus = CloudKeyStatus.RECOVERY_AUTH_REQUIRED
            null
        }
    }

    private fun finishPendingApproval(raw: String, accessToken: String) {
        require(hasBoundKey())
        val invitation = LibraryKeyBootstrap.PairingInvitation.fromQRPayload(raw)
        require(invitation.serverURL == configuration.serverURL)
        require(invitation.spaceID.equals(configuration.spaceID, ignoreCase = true))
        val serverPairing = client.pairing(
            invitation.serverURL,
            invitation.spaceID,
            invitation.pairingID,
            accessToken,
            requireServerInstanceID(),
        )
        validatePairing(
            serverPairing,
            invitation.pairingID,
            invitation.recipientPublicKey,
            invitation.nonce,
            invitation.expiresAtEpochSeconds,
        )
        require(serverPairing.authenticationTag == invitation.confirmationCode)
        require(serverPairing.algorithm == null && serverPairing.ciphertext == null)
        if (serverPairing.state == "approved") {
            // The approval may have committed even when its success response was lost.
            // The recipient remains the only party able to consume and decrypt it.
            store.delete(PENDING_APPROVAL)
            approvalConfirmationCode = null
            cloudKeyStatus = CloudKeyStatus.READY
            return
        }
        require(serverPairing.state == "pending")
        val ciphertext = LibraryKeyBootstrap.sealForPairing(
            requireNotNull(keys).toJSON(),
            invitation,
        )
        val approved = client.approvePairing(
            invitation.serverURL,
            invitation.spaceID,
            invitation.pairingID,
            invitation.recipientPublicKey,
            ciphertext,
            accessToken,
            requireServerInstanceID(),
        )
        validatePairing(
            approved,
            invitation.pairingID,
            invitation.recipientPublicKey,
            invitation.nonce,
            invitation.expiresAtEpochSeconds,
        )
        require(approved.state == "approved")
        require(approved.authenticationTag == invitation.confirmationCode)
        require(approved.algorithm == null && approved.ciphertext == null)
        store.delete(PENDING_APPROVAL)
        approvalConfirmationCode = null
        cloudKeyStatus = CloudKeyStatus.READY
    }

    private fun finishPendingRecovery(
        pending: PendingRecoveryUpload,
        accessToken: String,
    ): RecoveryKitPresentation {
        val kit = LibraryKeyBootstrap.RecoveryKit.fromQRPayload(pending.kitPayload)
        require(kit.serverURL == configuration.serverURL)
        require(kit.spaceID.equals(configuration.spaceID, ignoreCase = true))
        val stored = try {
            client.putRecoveryEnvelope(
                configuration.serverURL,
                configuration.spaceID,
                kit.keyEpoch,
                pending.expectedVersion,
                pending.ciphertext,
                accessToken,
                requireServerInstanceID(),
            )
        } catch (failure: SyncFailure) {
            if (failure.code != "conflict") throw failure
            // Recover a committed PUT whose response was lost. A different envelope
            // remains a real CAS conflict and must never authorize this provisional key.
            val current = client.recoveryEnvelope(
                configuration.serverURL,
                configuration.spaceID,
                accessToken,
                requireServerInstanceID(),
            )
            val existing = current.recovery
            if (current.keyEpoch != kit.keyEpoch ||
                existing?.algorithm != LibraryKeyBootstrap.RECOVERY_ALGORITHM ||
                existing.ciphertext.contentEquals(pending.ciphertext).not()) {
                throw failure
            }
            existing
        }
        require(stored.algorithm == LibraryKeyBootstrap.RECOVERY_ALGORITHM)
        require(stored.keyEpoch == kit.keyEpoch)
        pending.newLibraryBundleJSON?.let(::installCloudKey)
        store.write(RECOVERY_PRESENTATION, pending.kitPayload)
        store.delete(PENDING_RECOVERY)
        configuration = configuration.copy(provider = SyncProvider.SNIPPETS_CLOUD)
        // Durable state is always locked. The freshly authenticated caller receives
        // the only transient copy and owns its current on-screen presentation.
        cloudKeyStatus = CloudKeyStatus.RECOVERY_KIT_LOCKED
        return RecoveryKitPresentation(pending.kitPayload, kit.longCode)
    }

    private fun pendingPairing(): LibraryKeyBootstrap.PendingPairing =
        store.read(PENDING_PAIRING)?.let(LibraryKeyBootstrap.PendingPairing::fromJSON)
            ?: throw SyncFailure("pairing_missing")

    private fun validatePairing(
        pairing: HttpSyncClient.PairingRecord,
        expectedPairingID: String,
        recipientPublicKey: ByteArray,
        nonce: ByteArray,
        expectedExpiresAtEpochSeconds: Long? = null,
    ) {
        require(pairing.pairingID.equals(expectedPairingID, ignoreCase = true))
        require(pairing.spaceID.equals(configuration.spaceID, ignoreCase = true))
        require(pairing.recipientPublicKey.contentEquals(recipientPublicKey))
        require(pairing.nonce.contentEquals(nonce))
        val now = Instant.now().epochSecond
        require(pairing.expiresAtEpochSeconds > now - 30)
        require(pairing.expiresAtEpochSeconds <= now + 630)
        expectedExpiresAtEpochSeconds?.let {
            require(pairing.expiresAtEpochSeconds == it)
        }
    }

    private fun installCloudKey(bundleJSON: String) {
        val imported = keyBundle(bundleJSON)
        require(Base64.decode(imported.key, Base64.DEFAULT).size == 32)
        require(Base64.decode(imported.salt, Base64.DEFAULT).size == 32)
        require(imported.scopeID == "sync-v1")
        keys = imported
        store.write(KEYS, imported.toJSON())
        bindCurrentKey(configuration.serverURL, configuration.spaceID)
        baseJSON = "[]"
        remoteRecordsJSON = "[]"
        configuration = configuration.copy(
            provider = SyncProvider.SNIPPETS_CLOUD,
            cursor = null,
            scopeBinding = null,
            datasetGeneration = null,
            feedEpoch = null,
            lastSuccessfulSyncEpochSeconds = null,
        )
    }

    private fun bindCurrentKey(serverURL: String, spaceID: String) {
        keyBinding = CloudKeyBinding(serverURL.trim().trimEnd('/'), UUID.fromString(spaceID).toString())
        store.write(KEY_BINDING, requireNotNull(keyBinding).toJSON())
    }

    private fun hasBoundKey(): Boolean = keys != null && keyBinding?.let {
        it.serverURL == configuration.serverURL.trim().trimEnd('/') &&
            it.spaceID.equals(configuration.spaceID, ignoreCase = true)
    } == true

    private fun requireSignedInCoordinates() {
        if (store.read(PENDING_LOCAL_ERASE) != null || authenticator.hasPendingRevocation() ||
            pendingLibrarySelection != null ||
            configuration.serverURL.isBlank() || configuration.spaceID.isBlank() ||
            !authenticator.hasSession(configuration.serverURL)) {
            throw CloudAuthFailure("sign_in_required")
        }
        requireServerInstanceID()
    }

    private fun requireServerInstanceID(): String =
        configuration.serverInstanceID ?: throw SyncFailure("scope_review_required")

    private suspend fun freshPinnedAccessToken(): String {
        requireSignedInCoordinates()
        val token = authenticator.freshAccessToken(configuration.serverURL)
        val resolution = client.resolveSpace(
            configuration.serverURL,
            configuration.spaceID,
            token,
        )
        if (!resolution.serverInstanceID.equals(requireServerInstanceID(), ignoreCase = true)) {
            throw SyncFailure("scope_review_required")
        }
        return token
    }

    private fun clearBootstrapState() {
        listOf(
            PENDING_PAIRING,
            PENDING_APPROVAL,
            PENDING_RECOVERY,
            RECOVERY_PRESENTATION,
            PENDING_SPACE_SELECTION,
        ).forEach(store::delete)
        pairingQRCode = null
        pairingConfirmationCode = null
        pairingExpiresAtEpochSeconds = null
        approvalConfirmationCode = null
        pendingLibrarySelection = null
    }

    /**
     * Idempotent crash recovery for this-device logout. The remote library root is
     * removed first, one-time bootstrap/recovery material second, OAuth credentials
     * third, and visible account state last. The marker is always the final delete.
     */
    private fun completePendingLocalErase() {
        if (store.read(PENDING_LOCAL_ERASE) == null) return

        store.delete(KEYS)
        store.delete(KEY_BINDING)
        invalidateRecoveryVerification(store)
        keys = null
        keyBinding = null
        recoveryKitVerified = false

        clearBootstrapState()

        authenticator.forgetLocalSession()
        cloudSessionAvailable = false

        configuration = CloudConfiguration(provider = SyncProvider.DEVICE)
        baseJSON = "[]"
        remoteRecordsJSON = "[]"
        cloudKeyStatus = CloudKeyStatus.SIGNED_OUT
        persistSyncState()
        store.delete(PENDING_LOCAL_ERASE)
    }

    private suspend fun mutate(operation: suspend () -> Unit) {
        initialization.await()
        mutex.withLock {
            mutableState.value = mutableState.value.copy(isBusy = true, errorCode = null)
            try {
                withContext(Dispatchers.IO) { operation() }
                publish()
            } catch (error: CoreFailure) {
                publish(errorCode = error.code)
            } catch (error: CloudAuthFailure) {
                publish(errorCode = error.code)
            } catch (error: SyncFailure) {
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
        val effectiveError = errorCode ?: pendingLibrarySelection
            ?.let { "space_selection_required" }
        val signedIn = cloudSessionAvailable && configuration.serverURL.isNotBlank() &&
            cloudKeyStatus != CloudKeyStatus.SIGNED_OUT
        val stage = when {
            effectiveError != null -> CloudSetupStage.NEEDS_ATTENTION
            !signedIn -> CloudSetupStage.SIGNED_OUT
            cloudKeyStatus == CloudKeyStatus.WAITING_FOR_APPROVAL ->
                CloudSetupStage.WAITING_FOR_APPROVAL
            cloudKeyStatus == CloudKeyStatus.RECOVERY_KIT_LOCKED ||
                cloudKeyStatus == CloudKeyStatus.RECOVERY_AUTH_REQUIRED ->
                CloudSetupStage.RECOVERY_KIT_NEEDS_VERIFICATION
            cloudKeyStatus == CloudKeyStatus.NEEDS_TRUSTED_DEVICE_OR_RECOVERY ->
                CloudSetupStage.LIBRARY_LOCKED
            configuration.provider == SyncProvider.SNIPPETS_CLOUD &&
                configuration.lastSuccessfulSyncEpochSeconds != null ->
                CloudSetupStage.UP_TO_DATE
            else -> CloudSetupStage.ACCOUNT_CONNECTED
        }
        mutableState.value = LibraryState(
            snippets = snippets,
            provider = configuration.provider,
            syncLabel = label ?: if (effectiveError != null) {
                "Sync needs attention"
            } else when (configuration.provider) {
                SyncProvider.DEVICE -> "On device"
                SyncProvider.SNIPPETS_CLOUD ->
                    if (configuration.lastSuccessfulSyncEpochSeconds != null) "Up to date"
                    else "Account connected"
            },
            isBusy = false,
            errorCode = effectiveError,
            cloudKeyStatus = cloudKeyStatus,
            pairingQRCode = pairingQRCode,
            pairingConfirmationCode = pairingConfirmationCode,
            approvalConfirmationCode = approvalConfirmationCode,
            pairingExpiresAtEpochSeconds = pairingExpiresAtEpochSeconds,
            libraryID = libraryID(),
            libraryChoices = pendingLibrarySelection?.choices.orEmpty(),
            librarySwitchFromID = pendingLibrarySelection?.previousLibraryID,
            recoveryKitVerified = recoveryKitVerified,
            setupStage = stage)
    }

    private fun libraryID(): String? {
        if (!cloudSessionAvailable || configuration.spaceID.isBlank()) return null
        return cloudLibraryID(configuration.serverInstanceID.orEmpty(), configuration.spaceID)
    }

    private fun freshKeyBundle(): KeyBundle {
        val random = SecureRandom()
        return KeyBundle(
            key = ByteArray(32).also(random::nextBytes).base64(),
            salt = ByteArray(32).also(random::nextBytes).base64())
    }

    private data class PendingRecoveryUpload(
        val kitPayload: String,
        val ciphertext: ByteArray,
        val expectedVersion: Int?,
        val newLibraryBundleJSON: String?,
    ) {
        fun toJSON(): String = JSONObject()
            .put("schemaVersion", 1)
            .put("kitPayload", kitPayload)
            .put("ciphertext", Base64.encodeToString(ciphertext, Base64.NO_WRAP))
            .put("expectedVersion", expectedVersion ?: JSONObject.NULL)
            .put("newLibraryBundle", newLibraryBundleJSON ?: JSONObject.NULL)
            .toString()

        companion object {
            fun fromJSON(raw: String): PendingRecoveryUpload {
                val value = JSONObject(raw)
                require(value.getInt("schemaVersion") == 1)
                val ciphertext = Base64.decode(value.getString("ciphertext"), Base64.DEFAULT)
                require(ciphertext.size <= 4_096)
                require(Base64.encodeToString(ciphertext, Base64.NO_WRAP) ==
                    value.getString("ciphertext"))
                val bundle = if (value.isNull("newLibraryBundle")) null
                else value.getString("newLibraryBundle").also { candidate ->
                    val parsed = keyBundle(candidate)
                    require(Base64.decode(parsed.key, Base64.DEFAULT).size == 32)
                    require(Base64.decode(parsed.salt, Base64.DEFAULT).size == 32)
                    require(parsed.scopeID == "sync-v1")
                }
                return PendingRecoveryUpload(
                    kitPayload = value.getString("kitPayload"),
                    ciphertext = ciphertext,
                    expectedVersion = if (value.isNull("expectedVersion")) null
                    else value.getInt("expectedVersion"),
                    newLibraryBundleJSON = bundle,
                )
            }
        }
    }

    private data class PostAuthorizationCompletion(
        val recoveryKit: RecoveryKitPresentation?,
        val needsLibrarySelection: Boolean,
    )

    private data class PendingLibrarySelection(
        val serverURL: String,
        val choices: List<CloudLibraryChoice>,
        val previousLibraryID: String?,
    ) {
        fun toJSON(): String = JSONObject()
            .put("schemaVersion", 1)
            .put("serverURL", serverURL)
            .put("previousLibraryID", previousLibraryID ?: JSONObject.NULL)
            .put("choices", org.json.JSONArray().also { array ->
                choices.forEach { choice ->
                    array.put(JSONObject()
                        .put("spaceID", choice.spaceID)
                        .put("serverInstanceID", choice.serverInstanceID)
                        .put("role", choice.role))
                }
            })
            .toString()

        companion object {
            fun fromJSON(raw: String): PendingLibrarySelection {
                val value = JSONObject(raw)
                require(value.getInt("schemaVersion") == 1)
                val serverURL = value.getString("serverURL").trim().trimEnd('/')
                require(serverURL.startsWith("https://"))
                val array = value.getJSONArray("choices")
                require(array.length() in 1..100)
                val choices = (0 until array.length()).map { index ->
                    val choice = array.getJSONObject(index)
                    CloudLibraryChoice(
                        spaceID = UUID.fromString(choice.getString("spaceID")).toString(),
                        serverInstanceID = UUID.fromString(
                            choice.getString("serverInstanceID"),
                        ).toString(),
                        role = choice.getString("role").also {
                            require(it == "owner" || it == "writer" || it == "reader")
                        },
                    )
                }
                require(choices.map(CloudLibraryChoice::spaceID).distinct().size == choices.size)
                val previousLibraryID = if (value.isNull("previousLibraryID")) null
                else value.getString("previousLibraryID").also {
                    require(it.matches(Regex("^[0-9A-F]{8}$")))
                }
                return PendingLibrarySelection(serverURL, choices, previousLibraryID)
            }
        }
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
        private const val KEY_BINDING = "key-binding.enc"
        private const val PENDING_PAIRING = "pending-pairing.enc"
        private const val PENDING_APPROVAL = "pending-approval.enc"
        private const val PENDING_RECOVERY = "pending-recovery.enc"
        private const val RECOVERY_PRESENTATION = "recovery-presentation.enc"
        private const val PENDING_SPACE_SELECTION = "pending-space-selection.enc"
        private const val PENDING_LOCAL_ERASE = "cloud-local-erase.enc"
    }
}
