import CloudKit
import XCTest

@testable import Snippets

/// Pure coverage for the privacy boundary around `CKContainer.userRecordID()`.
/// Transport integration is exercised through the Core account-scoped round tests;
/// this suite proves that the value persisted in base.json is a domain-separated
/// digest, not Apple's stable record name.
final class CloudKitAccountIdentityTests: XCTestCase {

    func testIdentityIsDeterministicAndScopedToEnvironmentDatabaseUserAndContainer() throws {
        let userA = CKRecord.ID(recordName: "raw-cloudkit-user-A")
        let userB = CKRecord.ID(recordName: "raw-cloudkit-user-B")

        let first = CloudKitAccountIdentity.derive(
            containerIdentifier: "iCloud.com.khm.snippets",
            databaseScope: .private,
            environment: .production,
            userRecordID: userA)
        let repeated = CloudKitAccountIdentity.derive(
            containerIdentifier: "iCloud.com.khm.snippets",
            databaseScope: .private,
            environment: .production,
            userRecordID: CKRecord.ID(recordName: "raw-cloudkit-user-A"))
        let otherUser = CloudKitAccountIdentity.derive(
            containerIdentifier: "iCloud.com.khm.snippets",
            databaseScope: .private,
            environment: .production,
            userRecordID: userB)
        let otherContainer = CloudKitAccountIdentity.derive(
            containerIdentifier: "iCloud.com.example.other",
            databaseScope: .private,
            environment: .production,
            userRecordID: userA)
        let otherDatabase = CloudKitAccountIdentity.derive(
            containerIdentifier: "iCloud.com.khm.snippets",
            databaseScope: .public,
            environment: .production,
            userRecordID: userA)

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, otherUser)
        XCTAssertNotEqual(first, otherContainer)
        XCTAssertNotEqual(first, otherDatabase)
        XCTAssertEqual(first.data.count, 32, "persist only a SHA-256-sized opaque value")
    }

    func testDevelopmentAndProductionAreDistinctDomainSeparatedScopes() throws {
        let user = CKRecord.ID(recordName: "same-cloudkit-user")
        let development = CloudKitAccountIdentity.derive(
            containerIdentifier: "iCloud.com.khm.snippets",
            databaseScope: .private,
            environment: .development,
            userRecordID: user)
        let repeatedDevelopment = CloudKitAccountIdentity.derive(
            containerIdentifier: "iCloud.com.khm.snippets",
            databaseScope: .private,
            environment: .development,
            userRecordID: CKRecord.ID(recordName: "same-cloudkit-user"))
        let production = CloudKitAccountIdentity.derive(
            containerIdentifier: "iCloud.com.khm.snippets",
            databaseScope: .private,
            environment: .production,
            userRecordID: user)

        XCTAssertEqual(development, repeatedDevelopment)
        XCTAssertNotEqual(
            development,
            production,
            "a Development cursor/system field must never be accepted in Production")

        // These two tuples collapse to the same bytes if fields are concatenated without
        // domain boundaries. They must remain distinct even when an attacker-controlled
        // record name and a container string imitate the environment/scope components.
        let firstAmbiguousTuple = CloudKitAccountIdentity.derive(
            containerIdentifier: "iCloud.example",
            databaseScope: .private,
            environment: .development,
            userRecordID: CKRecord.ID(recordName: "privateproductionuser"))
        let secondAmbiguousTuple = CloudKitAccountIdentity.derive(
            containerIdentifier: "iCloud.exampleprivatedevelopment",
            databaseScope: .private,
            environment: .production,
            userRecordID: CKRecord.ID(recordName: "user"))
        XCTAssertNotEqual(firstAmbiguousTuple, secondAmbiguousTuple)
    }

    func testPersistedIdentityDoesNotContainCloudKitRecordName() throws {
        let rawRecordName = "raw-stable-cloudkit-user-record-name"
        let identity = CloudKitAccountIdentity.derive(
            containerIdentifier: "iCloud.com.khm.snippets",
            databaseScope: .private,
            environment: .production,
            userRecordID: CKRecord.ID(recordName: rawRecordName))

        let encoded = try JSONEncoder().encode(identity)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(text.contains(rawRecordName))
        XCTAssertFalse(identity.data.isEmpty)
    }

    func testInjectedResolverReturnsDerivedIdentityWithoutContactingCloudKit() async throws {
        let fixture = CloudKitAccountFixture(recordName: "injected-user-A")
        let transport = CloudKitTransport(
            accountStatusProvider: { fixture.accountStatus() },
            userRecordIDProvider: { fixture.userRecordID() },
            environmentProvider: { fixture.environment() })

        let resolved = try await transport.resolveAccountIdentity()

        XCTAssertEqual(resolved, CloudKitAccountIdentity.derive(
            containerIdentifier: CloudKitSchema.containerIdentifier,
            databaseScope: .private,
            environment: .production,
            userRecordID: CKRecord.ID(recordName: "injected-user-A")))
        XCTAssertEqual(fixture.environmentCalls, 1)
        XCTAssertEqual(fixture.statusCalls, 1)
        XCTAssertEqual(fixture.recordIDCalls, 1)
    }

    func testInjectedEnvironmentProviderSelectsTheResolvedIdentityScope() async throws {
        let fixture = CloudKitAccountFixture(
            recordName: "same-user-in-both-environments",
            environment: .development)
        let transport = CloudKitTransport(
            accountStatusProvider: { fixture.accountStatus() },
            userRecordIDProvider: { fixture.userRecordID() },
            environmentProvider: { fixture.environment() })

        let resolved = try await transport.resolveAccountIdentity()

        XCTAssertEqual(resolved, CloudKitAccountIdentity.derive(
            containerIdentifier: CloudKitSchema.containerIdentifier,
            databaseScope: .private,
            environment: .development,
            userRecordID: CKRecord.ID(recordName: "same-user-in-both-environments")))
        XCTAssertNotEqual(resolved, CloudKitAccountIdentity.derive(
            containerIdentifier: CloudKitSchema.containerIdentifier,
            databaseScope: .private,
            environment: .production,
            userRecordID: CKRecord.ID(recordName: "same-user-in-both-environments")))
        XCTAssertEqual(fixture.environmentCalls, 1)
        XCTAssertEqual(fixture.statusCalls, 1)
        XCTAssertEqual(fixture.recordIDCalls, 1)
    }

    func testEnvironmentIsSnapshottedExactlyOnceForTheTransportLifetime() async throws {
        let fixture = CloudKitAccountFixture(
            recordName: "stable-user",
            environment: .development)
        let transport = CloudKitTransport(
            accountStatusProvider: { fixture.accountStatus() },
            userRecordIDProvider: { fixture.userRecordID() },
            environmentProvider: { fixture.environment() })

        XCTAssertEqual(
            fixture.environmentCalls,
            1,
            "the signed-artifact environment must be captured during initialization")
        let resolved = try await transport.resolveAccountIdentity()
        XCTAssertEqual(resolved, CloudKitAccountIdentity.derive(
            containerIdentifier: CloudKitSchema.containerIdentifier,
            databaseScope: .private,
            environment: .development,
            userRecordID: CKRecord.ID(recordName: "stable-user")))

        fixture.containerEnvironment = .production

        let submission = try await transport.submit([], at: nil)
        let resolvedAgain = try await transport.resolveAccountIdentity()
        XCTAssertEqual(submission.accountIdentity, resolved)
        XCTAssertEqual(resolvedAgain, resolved)
        XCTAssertEqual(
            fixture.environmentCalls,
            1,
            "preflight must use the immutable process-lifetime routing coordinate")
        XCTAssertEqual(fixture.statusCalls, 3)
        XCTAssertEqual(fixture.recordIDCalls, 3)
    }

    func testUnrecognizedEnvironmentFailsClosedBeforeIdentityOrDataPlane() async throws {
        let fixture = CloudKitAccountFixture(
            recordName: "must-not-be-consulted",
            environment: .unrecognized)
        let transport = CloudKitTransport(
            accountStatusProvider: { fixture.accountStatus() },
            userRecordIDProvider: { fixture.userRecordID() },
            environmentProvider: { fixture.environment() })

        do {
            _ = try await transport.resolveAccountIdentity()
            XCTFail("an unrecognized CloudKit environment must not produce an identity")
        } catch let failure as SyncTransportFailure {
            XCTAssertEqual(failure, .rejected(.permanent(
                detail: "the signed app's CloudKit environment could not be verified")))
        } catch {
            XCTFail("unexpected failure type: \(type(of: error))")
        }

        XCTAssertEqual(fixture.environmentCalls, 1)
        XCTAssertEqual(fixture.statusCalls, 0)
        XCTAssertEqual(fixture.recordIDCalls, 0)

        do {
            _ = try await transport.submit([], at: nil)
            XCTFail("failed environment resolution must leave the data-plane gate closed")
        } catch let failure as SyncTransportFailure {
            XCTAssertEqual(failure, .unreachable(
                detail: "the iCloud account checkpoint has not been established"))
        } catch {
            XCTFail("unexpected failure type: \(type(of: error))")
        }
        XCTAssertEqual(fixture.environmentCalls, 1)
        XCTAssertEqual(fixture.statusCalls, 0)
        XCTAssertEqual(fixture.recordIDCalls, 0)
    }

    func testIdentityChangedAfterRoundResolutionRejectsSubmitBeforeDataPlane() async throws {
        let fixture = CloudKitAccountFixture(recordName: "injected-user-A")
        let transport = CloudKitTransport(
            accountStatusProvider: { fixture.accountStatus() },
            userRecordIDProvider: { fixture.userRecordID() },
            environmentProvider: { fixture.environment() })
        let accountA = try await transport.resolveAccountIdentity()
        fixture.recordName = "injected-user-B"

        do {
            _ = try await transport.submit([], at: SyncCursor("account-a-cursor"))
            XCTFail("a changed account must fail before even an empty submission is scoped")
        } catch let failure as SyncTransportFailure {
            XCTAssertEqual(failure, .accountChanged)
        }

        XCTAssertNotEqual(accountA, CloudKitAccountIdentity.derive(
            containerIdentifier: CloudKitSchema.containerIdentifier,
            databaseScope: .private,
            environment: .production,
            userRecordID: CKRecord.ID(recordName: fixture.recordName)))
        XCTAssertEqual(fixture.environmentCalls, 1)
        XCTAssertEqual(fixture.statusCalls, 2)
        XCTAssertEqual(fixture.recordIDCalls, 2)
    }

    func testAccountChangedNotificationInvalidatesPreparedOperationGate() async throws {
        let fixture = CloudKitAccountFixture(recordName: "injected-user-A")
        let transport = CloudKitTransport(
            accountStatusProvider: { fixture.accountStatus() },
            userRecordIDProvider: { fixture.userRecordID() },
            environmentProvider: { fixture.environment() })
        _ = try await transport.resolveAccountIdentity()

        NotificationCenter.default.post(name: .CKAccountChanged, object: nil)

        do {
            _ = try await transport.submit([], at: nil)
            XCTFail("an account-change hint must invalidate the operation and zone scope")
        } catch let failure as SyncTransportFailure {
            guard case .unreachable = failure else {
                return XCTFail("invalidated preflight should require a new resolution, got \(failure)")
            }
        }
        XCTAssertEqual(fixture.environmentCalls, 1)
        XCTAssertEqual(fixture.statusCalls, 1,
                       "an invalidated operation must stop before another provider/database call")
        XCTAssertEqual(fixture.recordIDCalls, 1)
    }
}

final class CloudKitRuntimeEnvironmentTests: XCTestCase {
    private let containerIdentifier = "iCloud.com.khm.snippets"
    private let environmentKey = "com.apple.developer.icloud-container-environment"
    private let containersKey = "com.apple.developer.icloud-container-identifiers"
    private let servicesKey = "com.apple.developer.icloud-services"

    func testExplicitProductionAndDevelopmentAreClassifiedExactly() throws {
        var production = validCloudKitEntitlements()
        production[environmentKey] = "Production"
        var development = validCloudKitEntitlements()
        development[environmentKey] = "Development"

        XCTAssertEqual(classify(production), .production)
        XCTAssertEqual(classify(development), .development)

        production[environmentKey] = "pRoDuCtIoN"
        development[environmentKey] = "dEvElOpMeNt"
        XCTAssertEqual(classify(production), .production)
        XCTAssertEqual(classify(development), .development)
    }

    func testMissingEnvironmentMeansDevelopmentOnlyForTheExpectedCloudKitScope() throws {
        let validWithoutEnvironment = validCloudKitEntitlements()

        XCTAssertNil(validWithoutEnvironment[environmentKey])
        XCTAssertEqual(classify(validWithoutEnvironment), .development)

        var missingService = validWithoutEnvironment
        missingService.removeValue(forKey: servicesKey)
        var wrongService = validWithoutEnvironment
        wrongService[servicesKey] = ["CloudDocuments"]
        var missingContainer = validWithoutEnvironment
        missingContainer.removeValue(forKey: containersKey)
        var wrongContainer = validWithoutEnvironment
        wrongContainer[containersKey] = ["iCloud.com.example.other"]

        for entitlements in [missingService, wrongService, missingContainer, wrongContainer] {
            XCTAssertEqual(classify(entitlements), .unrecognized)
        }
    }

    func testMalformedOrUnexpectedEntitlementValuesAreUnrecognized() throws {
        let malformed: [[String: Any]] = [
            [
                servicesKey: "CloudKit",
                containersKey: [containerIdentifier],
                environmentKey: "Production",
            ],
            [
                servicesKey: ["CloudKit"],
                containersKey: containerIdentifier,
                environmentKey: "Production",
            ],
            [
                servicesKey: [1],
                containersKey: [containerIdentifier],
                environmentKey: "Production",
            ],
            [
                servicesKey: ["CloudKit"],
                containersKey: [1],
                environmentKey: "Production",
            ],
            [
                servicesKey: ["CloudKit"],
                containersKey: [containerIdentifier],
                environmentKey: 1,
            ],
            [
                servicesKey: ["CloudKit"],
                containersKey: [containerIdentifier],
                environmentKey: ["Production"],
            ],
            [
                servicesKey: ["CloudKit"],
                containersKey: [containerIdentifier],
                environmentKey: "",
            ],
            [
                servicesKey: ["CloudKit"],
                containersKey: [containerIdentifier],
                environmentKey: "Staging",
            ],
        ]

        for (index, entitlements) in malformed.enumerated() {
            XCTAssertEqual(
                classify(entitlements),
                .unrecognized,
                "malformed entitlement case \(index) must fail closed")
        }
    }

    func testThinMachOParserExtractsTheSignedEntitlementDictionary() throws {
        var entitlements = validCloudKitEntitlements()
        entitlements[environmentKey] = "Production"
        let executable = try syntheticSignedMachO(entitlements: entitlements)

        let parsed = try XCTUnwrap(
            CloudKitRuntimeEnvironment.signedEntitlements(fromMachO: executable))

        XCTAssertEqual(parsed[environmentKey] as? String, "Production")
        XCTAssertEqual(parsed[servicesKey] as? [String], ["CloudKit"])
        XCTAssertEqual(parsed[containersKey] as? [String], [containerIdentifier])
        XCTAssertEqual(classify(parsed), .production)
    }

    func testEntitlementsSlotNeedNotBeFirstInSuperBlob() throws {
        var entitlements = validCloudKitEntitlements()
        entitlements[environmentKey] = "Production"
        let executable = try syntheticSignedMachO(
            entitlements: entitlements,
            leadingDecoySlot: true)

        let parsed = try XCTUnwrap(
            CloudKitRuntimeEnvironment.signedEntitlements(fromMachO: executable))

        XCTAssertEqual(classify(parsed), .production)
    }

    func testEntitlementSlotOffsetInsideSuperBlobIndexTableIsRejected() throws {
        var entitlements = validCloudKitEntitlements()
        entitlements[environmentKey] = "Production"
        let executable = try syntheticSignedMachOWithEntitlementInsideIndexTable(
            entitlements: entitlements)

        XCTAssertNil(
            CloudKitRuntimeEnvironment.signedEntitlements(fromMachO: executable),
            "an index entry must never be reinterpreted as its own entitlement blob")
    }

    func testFat32SelectsCurrentArchitectureAfterWrongArchitectureDecoy() throws {
        var decoyEntitlements = validCloudKitEntitlements()
        decoyEntitlements[environmentKey] = "Production"
        var currentEntitlements = validCloudKitEntitlements()
        currentEntitlements[environmentKey] = "Development"
        let decoy = try syntheticSignedMachO(entitlements: decoyEntitlements)
        let current = try syntheticSignedMachO(entitlements: currentEntitlements)
        let executable = syntheticFatMachO(
            slices: [
                (wrongCPUType, decoy),
                (currentCPUType, current),
            ],
            is64Bit: false,
            order: .big)

        let parsed = try XCTUnwrap(
            CloudKitRuntimeEnvironment.signedEntitlements(fromMachO: executable))

        XCTAssertEqual(
            classify(parsed),
            .development,
            "the LC_CODE_SIGNATURE offset must be interpreted relative to the selected slice")
    }

    func testSwappedEndianFat64SelectsCurrentArchitectureSlice() throws {
        var decoyEntitlements = validCloudKitEntitlements()
        decoyEntitlements[environmentKey] = "Development"
        var currentEntitlements = validCloudKitEntitlements()
        currentEntitlements[environmentKey] = "Production"
        let decoy = try syntheticSignedMachO(entitlements: decoyEntitlements)
        let current = try syntheticSignedMachO(
            entitlements: currentEntitlements,
            leadingDecoySlot: true)
        let executable = syntheticFatMachO(
            slices: [
                (wrongCPUType, decoy),
                (currentCPUType, current),
            ],
            is64Bit: true,
            order: .little)

        let parsed = try XCTUnwrap(
            CloudKitRuntimeEnvironment.signedEntitlements(fromMachO: executable))

        XCTAssertEqual(classify(parsed), .production)
    }

    func testMalformedCurrentFatSliceOffsetOrSizeReturnsNil() throws {
        var entitlements = validCloudKitEntitlements()
        entitlements[environmentKey] = "Production"
        let thin = try syntheticSignedMachO(entitlements: entitlements)
        let executable = syntheticFatMachO(
            slices: [
                (wrongCPUType, thin),
                (currentCPUType, thin),
            ],
            is64Bit: false,
            order: .big)
        XCTAssertNotNil(CloudKitRuntimeEnvironment.signedEntitlements(fromMachO: executable))

        // FAT32 header is 8 bytes and each fat_arch is 20 bytes. The current slice is
        // deliberately second, with offset/size at +8/+12 inside that entry.
        let currentEntry = 8 + 20
        let invalidOffset = replacingUInt32(
            in: executable,
            at: currentEntry + 8,
            with: .max,
            order: .big)
        let invalidSize = replacingUInt32(
            in: executable,
            at: currentEntry + 12,
            with: .max,
            order: .big)

        XCTAssertNil(CloudKitRuntimeEnvironment.signedEntitlements(fromMachO: invalidOffset))
        XCTAssertNil(CloudKitRuntimeEnvironment.signedEntitlements(fromMachO: invalidSize))
    }

    func testDuplicateCurrentCPUTypeSlicesFailClosed() throws {
        var firstEntitlements = validCloudKitEntitlements()
        firstEntitlements[environmentKey] = "Development"
        var secondEntitlements = validCloudKitEntitlements()
        secondEntitlements[environmentKey] = "Production"
        let first = try syntheticSignedMachO(entitlements: firstEntitlements)
        let second = try syntheticSignedMachO(entitlements: secondEntitlements)
        let executable = syntheticFatMachO(
            slices: [
                (currentCPUType, first),
                (currentCPUType, second),
            ],
            is64Bit: false,
            order: .big)

        XCTAssertNil(
            CloudKitRuntimeEnvironment.signedEntitlements(fromMachO: executable),
            "CPU type alone cannot prove which subtype-bearing slice is executing")
    }

    func testEveryTruncatedPrefixOfSignedMachOReturnsNil() throws {
        var entitlements = validCloudKitEntitlements()
        entitlements[environmentKey] = "Production"
        let executable = try syntheticSignedMachO(entitlements: entitlements)

        for end in 0..<executable.count {
            XCTAssertNil(
                CloudKitRuntimeEnvironment.signedEntitlements(
                    fromMachO: executable.prefix(end)),
                "prefix ending at byte \(end) must not be accepted")
        }
    }

    func testCorruptMachOOffsetsLengthsMagicAndPayloadReturnNil() throws {
        var entitlements = validCloudKitEntitlements()
        entitlements[environmentKey] = "Production"
        let executable = try syntheticSignedMachO(entitlements: entitlements)
        let signatureOffset = 48
        let entitlementBlobOffset = signatureOffset + 20
        let payloadOffset = entitlementBlobOffset + 8

        let corruptions: [(String, Data)] = [
            ("thin magic", replacingUInt32(in: executable, at: 0, with: 0, order: .little)),
            ("load-command size", replacingUInt32(
                in: executable, at: 36, with: 0, order: .little)),
            ("signature offset", replacingUInt32(
                in: executable, at: 40, with: .max, order: .little)),
            ("superblob magic", replacingUInt32(
                in: executable, at: signatureOffset, with: 0, order: .big)),
            ("superblob length", replacingUInt32(
                in: executable, at: signatureOffset + 4, with: .max, order: .big)),
            ("entitlement slot offset", replacingUInt32(
                in: executable, at: signatureOffset + 16, with: 0, order: .big)),
            ("entitlement blob length", replacingUInt32(
                in: executable, at: entitlementBlobOffset + 4, with: .max, order: .big)),
            ("property-list payload", replacingByte(
                in: executable, at: payloadOffset, with: 0xFF)),
        ]

        for (name, corrupted) in corruptions {
            XCTAssertNil(
                CloudKitRuntimeEnvironment.signedEntitlements(fromMachO: corrupted),
                "corrupt \(name) must fail closed")
        }
    }

    func testNonMachOAndMalformedFatHeadersReturnNil() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: validCloudKitEntitlements(),
            format: .xml,
            options: 0)
        var truncatedFatHeader = Data()
        appendUInt32(0xCAFE_BABE, order: .big, to: &truncatedFatHeader)
        appendUInt32(1, order: .big, to: &truncatedFatHeader)

        let invalidInputs = [
            Data(),
            Data([0x00, 0x01, 0x02, 0x03]),
            Data("not a Mach-O executable".utf8),
            plist,
            truncatedFatHeader,
        ]

        for input in invalidInputs {
            XCTAssertNil(CloudKitRuntimeEnvironment.signedEntitlements(fromMachO: input))
        }
    }

    #if targetEnvironment(simulator)
    func testSimulatorRuntimeEnvironmentIsDeterministicallyDevelopment() throws {
        XCTAssertEqual(
            CloudKitRuntimeEnvironment.current(containerIdentifier: containerIdentifier),
            .development)
    }
    #endif

    private func validCloudKitEntitlements() -> [String: Any] {
        [
            servicesKey: ["CloudKit"],
            containersKey: [containerIdentifier],
        ]
    }

    private func classify(
        _ entitlements: [String: Any]
    ) -> CloudKitContainerEnvironment {
        CloudKitRuntimeEnvironment.environment(
            fromSignedEntitlements: entitlements,
            containerIdentifier: containerIdentifier)
    }
}

private enum TestByteOrder {
    case little
    case big
}

private func syntheticSignedMachO(
    entitlements: [String: Any],
    leadingDecoySlot: Bool = false
) throws -> Data {
    let payload = try PropertyListSerialization.data(
        fromPropertyList: entitlements,
        format: .xml,
        options: 0)

    var entitlementBlob = Data()
    appendUInt32(0xFADE_7171, order: .big, to: &entitlementBlob)
    appendUInt32(UInt32(8 + payload.count), order: .big, to: &entitlementBlob)
    entitlementBlob.append(payload)

    let indexCount: UInt32 = leadingDecoySlot ? 2 : 1
    let firstBlobOffset = 12 + Int(indexCount) * 8
    let decoyBlob = leadingDecoySlot ? Data(repeating: 0xA5, count: 8) : Data()
    let entitlementOffset = firstBlobOffset + decoyBlob.count

    var signature = Data()
    appendUInt32(0xFADE_0CC0, order: .big, to: &signature)
    appendUInt32(
        UInt32(entitlementOffset + entitlementBlob.count),
        order: .big,
        to: &signature)
    appendUInt32(indexCount, order: .big, to: &signature)
    if leadingDecoySlot {
        appendUInt32(0, order: .big, to: &signature)
        appendUInt32(UInt32(firstBlobOffset), order: .big, to: &signature)
    }
    appendUInt32(5, order: .big, to: &signature)
    appendUInt32(UInt32(entitlementOffset), order: .big, to: &signature)
    signature.append(decoyBlob)
    signature.append(entitlementBlob)

    return syntheticThinMachO(codeSignature: signature)
}

private func syntheticSignedMachOWithEntitlementInsideIndexTable(
    entitlements: [String: Any]
) throws -> Data {
    let payload = try PropertyListSerialization.data(
        fromPropertyList: entitlements,
        format: .xml,
        options: 0)

    // The first index claims slot 5 starts at byte 20, which is actually the second
    // index. That second index is shaped like an entitlement blob header and the XML
    // follows the index table, so a parser checking only magic/length would accept it.
    var signature = Data()
    appendUInt32(0xFADE_0CC0, order: .big, to: &signature)
    appendUInt32(UInt32(28 + payload.count), order: .big, to: &signature)
    appendUInt32(2, order: .big, to: &signature)
    appendUInt32(5, order: .big, to: &signature)
    appendUInt32(20, order: .big, to: &signature)
    appendUInt32(0xFADE_7171, order: .big, to: &signature)
    appendUInt32(UInt32(8 + payload.count), order: .big, to: &signature)
    signature.append(payload)
    return syntheticThinMachO(codeSignature: signature)
}

private func syntheticThinMachO(codeSignature: Data) -> Data {
    var executable = Data()
    appendUInt32(0xFEED_FACF, order: .little, to: &executable)
    #if arch(arm64)
    appendUInt32(0x0100_000C, order: .little, to: &executable)
    #elseif arch(x86_64)
    appendUInt32(0x0100_0007, order: .little, to: &executable)
    #else
    appendUInt32(0, order: .little, to: &executable)
    #endif
    appendUInt32(0, order: .little, to: &executable) // CPU subtype
    appendUInt32(2, order: .little, to: &executable) // MH_EXECUTE
    appendUInt32(1, order: .little, to: &executable) // command count
    appendUInt32(16, order: .little, to: &executable) // command bytes
    appendUInt32(0, order: .little, to: &executable) // flags
    appendUInt32(0, order: .little, to: &executable) // reserved

    appendUInt32(0x1D, order: .little, to: &executable) // LC_CODE_SIGNATURE
    appendUInt32(16, order: .little, to: &executable)
    appendUInt32(48, order: .little, to: &executable)
    appendUInt32(UInt32(codeSignature.count), order: .little, to: &executable)
    executable.append(codeSignature)
    return executable
}

private var currentCPUType: UInt32 {
    #if arch(arm64)
    0x0100_000C
    #elseif arch(x86_64)
    0x0100_0007
    #else
    0
    #endif
}

private var wrongCPUType: UInt32 {
    #if arch(arm64)
    0x0100_0007
    #else
    0x0100_000C
    #endif
}

private func syntheticFatMachO(
    slices: [(cpuType: UInt32, data: Data)],
    is64Bit: Bool,
    order: TestByteOrder
) -> Data {
    let stride = is64Bit ? 32 : 20
    var nextOffset = 8 + slices.count * stride
    let positioned = slices.map { slice -> (UInt32, Int, Data) in
        defer { nextOffset += slice.data.count }
        return (slice.cpuType, nextOffset, slice.data)
    }

    var executable = Data()
    let canonicalMagic: UInt32 = is64Bit ? 0xCAFE_BABF : 0xCAFE_BABE
    appendUInt32(canonicalMagic, order: order, to: &executable)
    appendUInt32(UInt32(slices.count), order: order, to: &executable)
    for (cpuType, offset, data) in positioned {
        appendUInt32(cpuType, order: order, to: &executable)
        appendUInt32(0, order: order, to: &executable) // CPU subtype
        if is64Bit {
            appendUInt64(UInt64(offset), order: order, to: &executable)
            appendUInt64(UInt64(data.count), order: order, to: &executable)
            appendUInt32(0, order: order, to: &executable) // alignment
            appendUInt32(0, order: order, to: &executable) // reserved
        } else {
            appendUInt32(UInt32(offset), order: order, to: &executable)
            appendUInt32(UInt32(data.count), order: order, to: &executable)
            appendUInt32(0, order: order, to: &executable) // alignment
        }
    }
    for (_, _, data) in positioned { executable.append(data) }
    return executable
}

private func replacingUInt32(
    in data: Data,
    at offset: Int,
    with value: UInt32,
    order: TestByteOrder
) -> Data {
    var replacement = Data()
    appendUInt32(value, order: order, to: &replacement)
    var result = data
    result.replaceSubrange(offset..<(offset + 4), with: replacement)
    return result
}

private func replacingByte(in data: Data, at offset: Int, with value: UInt8) -> Data {
    var result = data
    result[offset] = value
    return result
}

private func appendUInt32(
    _ value: UInt32,
    order: TestByteOrder,
    to data: inout Data
) {
    var encoded: UInt32
    switch order {
    case .little: encoded = value.littleEndian
    case .big: encoded = value.bigEndian
    }
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}

private func appendUInt64(
    _ value: UInt64,
    order: TestByteOrder,
    to data: inout Data
) {
    var encoded: UInt64
    switch order {
    case .little: encoded = value.littleEndian
    case .big: encoded = value.bigEndian
    }
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}

nonisolated private final class CloudKitAccountFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var statusStorage: CKAccountStatus = .available
    private var recordNameStorage: String
    private var environmentStorage: CloudKitContainerEnvironment
    private var statusCallCount = 0
    private var recordIDCallCount = 0
    private var environmentCallCount = 0

    init(
        recordName: String,
        environment: CloudKitContainerEnvironment = .production
    ) {
        recordNameStorage = recordName
        environmentStorage = environment
    }

    var recordName: String {
        get { lock.withLock { recordNameStorage } }
        set { lock.withLock { recordNameStorage = newValue } }
    }

    var containerEnvironment: CloudKitContainerEnvironment {
        get { lock.withLock { environmentStorage } }
        set { lock.withLock { environmentStorage = newValue } }
    }

    var environmentCalls: Int { lock.withLock { environmentCallCount } }
    var statusCalls: Int { lock.withLock { statusCallCount } }
    var recordIDCalls: Int { lock.withLock { recordIDCallCount } }

    func environment() -> CloudKitContainerEnvironment {
        lock.withLock {
            environmentCallCount += 1
            return environmentStorage
        }
    }

    func accountStatus() -> CKAccountStatus {
        lock.withLock {
            statusCallCount += 1
            return statusStorage
        }
    }

    func userRecordID() -> CKRecord.ID {
        lock.withLock {
            recordIDCallCount += 1
            return CKRecord.ID(recordName: recordNameStorage)
        }
    }
}
