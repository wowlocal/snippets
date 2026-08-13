import Foundation

public protocol SyncStore: Sendable {
    func readiness() async throws
    func listSpaces(for principal: AuthenticatedPrincipal) async throws -> [SpaceDescriptor]
    func createSpace(for principal: AuthenticatedPrincipal, idempotencyKey: UUID?) async throws -> SpaceDescriptor
    func scope(for principal: AuthenticatedPrincipal, spaceID: UUID) async throws -> SpaceDescriptor
    func fetchChanges(for principal: AuthenticatedPrincipal, spaceID: UUID, cursor: String?, limit: Int) async throws -> ChangesPage
    func submit(for principal: AuthenticatedPrincipal, spaceID: UUID, items: [BatchItem]) async throws -> BatchSubmission
    func currentKeyEnvelope(for principal: AuthenticatedPrincipal, spaceID: UUID) async throws -> (SpaceDescriptor, KeyEnvelope?)
    func putKeyEnvelope(for principal: AuthenticatedPrincipal, spaceID: UUID, request: PutKeyEnvelope) async throws -> KeyEnvelope
    func createPairing(for principal: AuthenticatedPrincipal, spaceID: UUID, request: CreatePairing) async throws -> Pairing
    func approvePairing(for principal: AuthenticatedPrincipal, spaceID: UUID, pairingID: UUID, request: ApprovePairing) async throws -> Pairing
    func pairing(for principal: AuthenticatedPrincipal, spaceID: UUID, pairingID: UUID) async throws -> Pairing
    func consumePairing(for principal: AuthenticatedPrincipal, spaceID: UUID, pairingID: UUID) async throws
}
