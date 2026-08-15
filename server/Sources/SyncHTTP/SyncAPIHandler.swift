import Foundation
import SyncDomain
import SyncOpenAPI

public struct SyncAPIHandler: APIProtocol {
    private let store: any SyncStore
    private let discovery: Components.Schemas.Discovery
    private let readinessTimeout: Duration

    public init(store: any SyncStore, configuration: ServerConfiguration) {
        self.store = store
        self.readinessTimeout = .seconds(configuration.httpReadinessTimeoutSeconds)
        self.discovery = .init(
            protocolMajor: ._1,
            protocolMinor: 4,
            serverVersion: configuration.serverVersion,
            serverInstanceId: configuration.serverInstanceID.uuidString.lowercased(),
            apiBase: configuration.publicBaseURL.absoluteString,
            oidc: .init(
                issuer: configuration.oidc.issuer.absoluteString,
                resource: configuration.publicBaseURL.absoluteString,
                clientId: configuration.oidc.clientID,
                scopes: configuration.oidc.scopes,
                authorizationFlow: .authorizationCodePkce,
                maxAccessTokenAgeSeconds: Int(configuration.oidc.maximumTokenAge),
                stepUpMaxAgeSeconds: Int(configuration.oidc.stepUpMaximumAge),
                stepUpAMRValues: configuration.oidc.stepUpAuthenticationMethods.sorted(),
                stepUpACRValues: configuration.oidc.stepUpAuthenticationContexts.sorted()
            ),
            limits: .init(
                maxBlobBytes: ._900000,
                maxRevisionBytes: ._256,
                maxBatchRecords: SyncLimits.maxBatchRecords,
                maxPageRecords: SyncLimits.maxPageRecords,
                maxRequestBytes: SyncLimits.maxRequestBytes,
                maxResponseBytes: SyncLimits.maxResponseBytes,
                maxKeyEnvelopeBytes: SyncLimits.maxKeyEnvelopeBytes,
                maxPairingSeconds: SyncLimits.maxPairingSeconds
            ),
            recordProfile: .snippetsWireV1,
            capabilities: [
                "oidc-pkce",
                "oauth-resource-indicators",
                "oauth-token-revocation",
                "resource-session-revocation",
                "account-without-required-email",
                "phishing-resistant-step-up",
                "pairing-v2",
                "offline-recovery-v1",
            ]
        )
    }

    public func getDiscovery(_ input: Operations.GetDiscovery.Input) async throws -> Operations.GetDiscovery.Output {
        .ok(.init(body: .json(discovery)))
    }

    public func getLiveness(_ input: Operations.GetLiveness.Input) async throws -> Operations.GetLiveness.Output {
        .ok(.init(body: .json(.init(status: .ok))))
    }

    public func getReadiness(_ input: Operations.GetReadiness.Input) async throws -> Operations.GetReadiness.Output {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await store.readiness() }
                group.addTask {
                    try await Task.sleep(for: readinessTimeout)
                    throw ReadinessProbeError.timedOut
                }
                _ = try await group.next()
                group.cancelAll()
            }
            return .ok(.init(body: .json(.init(status: .ok))))
        } catch {
            return .serviceUnavailable(.init(body: .json(OpenAPIMapping.error(.dependencyUnavailable))))
        }
    }

    public func revokeCurrentSession(
        _ input: Operations.RevokeCurrentSession.Input
    ) async throws -> Operations.RevokeCurrentSession.Output {
        let principal = try OpenAPIMapping.requiredPrincipal()
        try await store.revokeAccessToken(for: principal)
        return .noContent(.init())
    }

    public func listSpaces(_ input: Operations.ListSpaces.Input) async throws -> Operations.ListSpaces.Output {
        let principal = try OpenAPIMapping.requiredPrincipal()
        let spaces = try await store.listSpaces(for: principal).map(OpenAPIMapping.space)
        return .ok(.init(body: .json(.init(spaces: spaces))))
    }

    public func createSpace(_ input: Operations.CreateSpace.Input) async throws -> Operations.CreateSpace.Output {
        let principal = try OpenAPIMapping.requiredPrincipal()
        let body: Components.Schemas.CreateSpaceRequest
        switch input.body { case .json(let value): body = value }
        let idempotency: UUID?
        if let raw = body.idempotencyKey {
            idempotency = try OpenAPIMapping.uuid(raw)
        } else {
            idempotency = nil
        }
        let created = try await store.createSpace(for: principal, idempotencyKey: idempotency)
        return .created(.init(body: .json(OpenAPIMapping.space(created))))
    }

    public func getScope(_ input: Operations.GetScope.Input) async throws -> Operations.GetScope.Output {
        let principal = try OpenAPIMapping.requiredPrincipal()
        let value = try await store.scope(for: principal, spaceID: OpenAPIMapping.uuid(input.path.space))
        return .ok(.init(body: .json(OpenAPIMapping.scope(value.scope))))
    }

    public func getChanges(_ input: Operations.GetChanges.Input) async throws -> Operations.GetChanges.Output {
        let principal = try OpenAPIMapping.requiredPrincipal()
        let limit = input.query.limit ?? SyncLimits.maxPageRecords
        let page = try await store.fetchChanges(
            for: principal,
            spaceID: OpenAPIMapping.uuid(input.path.space),
            cursor: input.query.cursor,
            limit: limit
        )
        return .ok(.init(body: .json(OpenAPIMapping.changes(page))))
    }

    public func submitRecords(_ input: Operations.SubmitRecords.Input) async throws -> Operations.SubmitRecords.Output {
        let principal = try OpenAPIMapping.requiredPrincipal()
        let request: Components.Schemas.BatchRequest
        switch input.body { case .json(let value): request = value }
        guard !request.items.isEmpty, request.items.count <= SyncLimits.maxBatchRecords else {
            throw SyncServiceError.invalidRequest
        }
        let items = try request.items.map { item in
            BatchItem(
                record: try OpenAPIMapping.wire(item.record),
                expectedRecordVersion: item.expectedRecordVersion
            )
        }
        let result = try await store.submit(
            for: principal,
            spaceID: OpenAPIMapping.uuid(input.path.space),
            items: items
        )
        return .ok(.init(body: .json(OpenAPIMapping.batch(result))))
    }

    public func getCurrentKeyEnvelopes(
        _ input: Operations.GetCurrentKeyEnvelopes.Input
    ) async throws -> Operations.GetCurrentKeyEnvelopes.Output {
        let principal = try OpenAPIMapping.requiredPrincipal()
        let (space, envelope) = try await store.currentKeyEnvelope(
            for: principal,
            spaceID: OpenAPIMapping.uuid(input.path.space)
        )
        let result = Components.Schemas.KeyEnvelopeSet(
            value1: OpenAPIMapping.scope(space.scope),
            value2: .init(keyEpoch: space.keyEpoch, recovery: envelope.map(OpenAPIMapping.keyEnvelope))
        )
        return .ok(.init(body: .json(result)))
    }

    public func putRecoveryKeyEnvelope(
        _ input: Operations.PutRecoveryKeyEnvelope.Input
    ) async throws -> Operations.PutRecoveryKeyEnvelope.Output {
        let principal = try OpenAPIMapping.requiredPrincipal()
        let body: Components.Schemas.PutKeyEnvelopeRequest
        switch input.body { case .json(let value): body = value }
        let request = PutKeyEnvelope(
            expectedVersion: body.expectedVersion,
            keyEpoch: body.keyEpoch,
            algorithm: body.algorithm.rawValue,
            ciphertext: try OpenAPIMapping.canonicalBase64(
                body.ciphertext,
                maximumBytes: SyncLimits.maxBootstrapEnvelopeBytes)
        )
        let stored = try await store.putKeyEnvelope(
            for: principal,
            spaceID: OpenAPIMapping.uuid(input.path.space),
            request: request
        )
        return .ok(.init(body: .json(OpenAPIMapping.keyEnvelope(stored))))
    }

    public func createPairing(_ input: Operations.CreatePairing.Input) async throws -> Operations.CreatePairing.Output {
        let principal = try OpenAPIMapping.requiredPrincipal()
        let body: Components.Schemas.CreatePairingRequest
        switch input.body { case .json(let value): body = value }
        let request = CreatePairing(
            recipientPublicKey: try OpenAPIMapping.canonicalBase64(
                body.recipientPublicKey,
                maximumBytes: SyncLimits.maxPairingPublicKeyBytes
            ),
            nonce: try OpenAPIMapping.canonicalBase64(body.nonce, maximumBytes: 32),
            expiresInSeconds: body.expiresInSeconds
        )
        let created = try await store.createPairing(
            for: principal,
            spaceID: OpenAPIMapping.uuid(input.path.space),
            request: request
        )
        return .created(.init(body: .json(OpenAPIMapping.pairing(created))))
    }

    public func getPairing(_ input: Operations.GetPairing.Input) async throws -> Operations.GetPairing.Output {
        let principal = try OpenAPIMapping.requiredPrincipal()
        let value = try await store.pairing(
            for: principal,
            spaceID: OpenAPIMapping.uuid(input.path.space),
            pairingID: OpenAPIMapping.uuid(input.path.pairing)
        )
        return .ok(.init(body: .json(OpenAPIMapping.pairing(value))))
    }

    public func consumePairing(_ input: Operations.ConsumePairing.Input) async throws -> Operations.ConsumePairing.Output {
        let principal = try OpenAPIMapping.requiredPrincipal()
        try await store.consumePairing(
            for: principal,
            spaceID: OpenAPIMapping.uuid(input.path.space),
            pairingID: OpenAPIMapping.uuid(input.path.pairing)
        )
        return .noContent(.init())
    }

    public func takeApprovedPairing(_ input: Operations.TakeApprovedPairing.Input) async throws -> Operations.TakeApprovedPairing.Output {
        let principal = try OpenAPIMapping.requiredPrincipal()
        let value = try await store.takeApprovedPairing(
            for: principal,
            spaceID: OpenAPIMapping.uuid(input.path.space),
            pairingID: OpenAPIMapping.uuid(input.path.pairing)
        )
        return .ok(.init(body: .json(OpenAPIMapping.pairing(
            value,
            includeApprovedEnvelope: true
        ))))
    }

    public func approvePairing(_ input: Operations.ApprovePairing.Input) async throws -> Operations.ApprovePairing.Output {
        let principal = try OpenAPIMapping.requiredPrincipal()
        let body: Components.Schemas.ApprovePairingRequest
        switch input.body { case .json(let value): body = value }
        let request = ApprovePairing(
            recipientKeyHash: try OpenAPIMapping.canonicalBase64(body.recipientKeyHash, maximumBytes: 32),
            algorithm: body.algorithm.rawValue,
            ciphertext: try OpenAPIMapping.canonicalBase64(
                body.ciphertext,
                maximumBytes: SyncLimits.maxBootstrapEnvelopeBytes)
        )
        let value = try await store.approvePairing(
            for: principal,
            spaceID: OpenAPIMapping.uuid(input.path.space),
            pairingID: OpenAPIMapping.uuid(input.path.pairing),
            request: request
        )
        return .ok(.init(body: .json(OpenAPIMapping.pairing(value))))
    }
}

private enum ReadinessProbeError: Error {
    case timedOut
}
