import CryptoKit
import Foundation

/// Only device identity is exchanged before a user approves pairing.
/// Neither discovery nor pairing carries hardware or simulation metrics.
public struct ClusterPeerHello: Codable, Equatable, Sendable {
    public let version: Int
    public let id: String
    public let name: String
    public let publicKey: Data

    public init(id: String, name: String, publicKey: Data) {
        self.version = 2
        self.id = String(id.prefix(64))
        self.name = String(name.prefix(64))
        self.publicKey = publicKey
    }

    public var isValid: Bool {
        version == 2 && !id.isEmpty && !name.isEmpty &&
        publicKey.count == 32 &&
        (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)) != nil
    }
}

public enum ClusterPairingError: Error {
    case invalidPublicKey
}

/// X25519 authenticated out-of-band using the same six-digit short
/// authentication string on both displays. A matching code must be verified
/// by the user on BOTH Macs before either trusts the other.
public enum ClusterPairing {
    public static func sessionKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePublicKey: Data
    ) throws -> Data {
        guard remotePublicKey.count == 32 else {
            throw ClusterPairingError.invalidPublicKey
        }
        let remote = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: remotePublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: remote)
        let local = privateKey.publicKey.rawRepresentation
        let ordered = local.lexicographicallyPrecedes(remotePublicKey)
            ? local + remotePublicKey : remotePublicKey + local
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("ChipBar Cluster pairing v2".utf8),
            sharedInfo: ordered,
            outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    public static func verificationCode(
        sessionKey: Data, localPublicKey: Data, remotePublicKey: Data
    ) -> String {
        let ordered = localPublicKey.lexicographicallyPrecedes(remotePublicKey)
            ? localPublicKey + remotePublicKey : remotePublicKey + localPublicKey
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data("ChipBar visual confirmation v2".utf8) + ordered,
            using: SymmetricKey(data: sessionKey))
        let number = signature.prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        } % 1_000_000
        return String(format: "%06d", number)
    }
}

/// A bounded length-prefixed packet. Hello frames are untrusted; telemetry
/// frames remain encrypted and require that a peer was explicitly trusted.
public enum ClusterPacket {
    public static let hello: UInt8 = 1
    public static let telemetry: UInt8 = 2
    public static let approval: UInt8 = 3

    public static func encode(type: UInt8, body: Data) -> Data? {
        guard (type == hello || type == telemetry || type == approval),
              !body.isEmpty, body.count + 1 <= ClusterSecureWire.maximumFrameBytes
        else { return nil }
        let size = UInt32(body.count + 1)
        return Data([
            UInt8(truncatingIfNeeded: size >> 24),
            UInt8(truncatingIfNeeded: size >> 16),
            UInt8(truncatingIfNeeded: size >> 8),
            UInt8(truncatingIfNeeded: size),
            type
        ]) + body
    }
}
