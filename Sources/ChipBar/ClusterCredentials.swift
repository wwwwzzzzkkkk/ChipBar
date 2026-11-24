import CryptoKit
import Foundation

/// The long-term device key and the peers it trusts must move together.
struct ClusterCredentials: Codable, Equatable {
    enum Account: String {
        case current = "cluster-credentials-v3"
        case legacyIdentity = "identity-x25519-v2"
        case legacyPeers = "trusted-device-keys-v2"
    }

    enum LoadError: Error {
        case missingIdentity
        case missingCurrentRecord
    }

    let identity: Data
    let trustedPeers: [String: Data]

    static func load(requireCurrent: Bool, createIdentity: Bool,
                     read: (Account) throws -> Data?,
                     create: (Data) throws -> Void) throws -> ClusterCredentials {
        if let data = try read(.current) {
            let credentials = try JSONDecoder().decode(Self.self, from: data)
            _ = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: credentials.identity)
            return credentials
        }

        // Once migrated, missing or inaccessible data must never resurrect
        // an older trust list, which can still include a forgotten device.
        guard !requireCurrent else { throw LoadError.missingCurrentRecord }
        let oldIdentity = try read(.legacyIdentity)
        let oldPeers = try read(.legacyPeers)
        let peers = try oldPeers.map { try JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
        let key: Curve25519.KeyAgreement.PrivateKey
        if let oldIdentity {
            key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: oldIdentity)
        } else {
            guard createIdentity, peers.isEmpty else { throw LoadError.missingIdentity }
            key = Curve25519.KeyAgreement.PrivateKey()
        }
        let credentials = Self(identity: key.rawRepresentation, trustedPeers: peers)
        try create(JSONEncoder().encode(credentials))
        return credentials
    }
}
