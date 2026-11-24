import CryptoKit
import Foundation
import Testing
@testable import ChipBar

struct ClusterCredentialsTests {
    private enum StoreFailure: Error { case denied, cannotWrite }

    @Test func migratesBothLegacyItemsAndLaterReadsOnlyTheCombinedRecord() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let peer = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let trusted = ["paired-mac": peer]
        var storage: [ClusterCredentials.Account: Data] = [
            .legacyIdentity: key.rawRepresentation,
            .legacyPeers: try JSONEncoder().encode(trusted)
        ]
        var reads: [ClusterCredentials.Account] = []
        let read: (ClusterCredentials.Account) -> Data? = { account in
            reads.append(account)
            return storage[account]
        }

        let migrated = try ClusterCredentials.load(requireCurrent: false, createIdentity: false,
                                                   read: read, create: { storage[.current] = $0 })
        #expect(reads == [.current, .legacyIdentity, .legacyPeers])
        #expect(migrated.identity == key.rawRepresentation)
        #expect(migrated.trustedPeers == trusted)

        reads.removeAll()
        let restored = try ClusterCredentials.load(requireCurrent: true, createIdentity: false,
                                                   read: read, create: { _ in Issue.record("Unexpected write") })
        #expect(restored == migrated)
        #expect(reads == [.current])
    }

    @Test func anAuthorizationDenialNeverReadsLegacyRecordsOrCreatesAnIdentity() {
        var reads: [ClusterCredentials.Account] = []
        #expect(throws: StoreFailure.denied) {
            try ClusterCredentials.load(requireCurrent: false, createIdentity: true, read: { account in
                reads.append(account)
                throw StoreFailure.denied
            }, create: { _ in Issue.record("Unexpected write") })
        }
        #expect(reads == [.current])
    }

    @Test func aMissingMigratedRecordNeverRestoresAnOlderTrustList() {
        var reads: [ClusterCredentials.Account] = []
        #expect(throws: ClusterCredentials.LoadError.missingCurrentRecord) {
            try ClusterCredentials.load(requireCurrent: true, createIdentity: true, read: { account in
                reads.append(account)
                return nil
            }, create: { _ in Issue.record("Unexpected write") })
        }
        #expect(reads == [.current])
    }

    @Test func migrationOnlyReturnsCredentialsAfterTheCombinedRecordIsSaved() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        #expect(throws: StoreFailure.cannotWrite) {
            try ClusterCredentials.load(requireCurrent: false, createIdentity: false, read: { account in
                account == .legacyIdentity ? key.rawRepresentation : nil
            }, create: { _ in throw StoreFailure.cannotWrite })
        }
    }
}
