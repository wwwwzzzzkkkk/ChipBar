import CryptoKit
import Foundation
import XCTest
@testable import ChipBarCore

final class ClusterPairingTests: XCTestCase {
    func testBothMacsDeriveSameKeyAndVerificationCode() throws {
        let mini = Curve25519.KeyAgreement.PrivateKey()
        let book = Curve25519.KeyAgreement.PrivateKey()
        let miniKey = try ClusterPairing.sessionKey(
            privateKey: mini, remotePublicKey: book.publicKey.rawRepresentation)
        let bookKey = try ClusterPairing.sessionKey(
            privateKey: book, remotePublicKey: mini.publicKey.rawRepresentation)
        XCTAssertEqual(miniKey, bookKey)
        XCTAssertEqual(miniKey.count, 32)

        let miniCode = ClusterPairing.verificationCode(
            sessionKey: miniKey, localPublicKey: mini.publicKey.rawRepresentation,
            remotePublicKey: book.publicKey.rawRepresentation)
        let bookCode = ClusterPairing.verificationCode(
            sessionKey: bookKey, localPublicKey: book.publicKey.rawRepresentation,
            remotePublicKey: mini.publicKey.rawRepresentation)
        XCTAssertEqual(miniCode, bookCode)
        XCTAssertEqual(miniCode.count, 6)
        XCTAssertTrue(miniCode.allSatisfy(\.isNumber))
    }

    func testDifferentPeerCannotUseExistingPairingKey() throws {
        let mini = Curve25519.KeyAgreement.PrivateKey()
        let book = Curve25519.KeyAgreement.PrivateKey()
        let other = Curve25519.KeyAgreement.PrivateKey()
        let original = try ClusterPairing.sessionKey(
            privateKey: mini, remotePublicKey: book.publicKey.rawRepresentation)
        let different = try ClusterPairing.sessionKey(
            privateKey: mini, remotePublicKey: other.publicKey.rawRepresentation)
        XCTAssertNotEqual(original, different)
        let observation = ClusterNodeReadout(
            id: "node", name: "Mac", chip: "M1 Pro", timestamp: Date(),
            cpu: 20, gpu: 30, memoryUsedGB: 4, memoryTotalGB: 16,
            chipWatts: 12, cpuTemperatureC: nil, tasks: [])
        let framed = try ClusterSecureWire.seal(observation, key: original)
        XCTAssertThrowsError(try ClusterSecureWire.open(
            Data(framed.dropFirst(4)), key: different))
    }

    func testHelloIsLimitedToIdentityNotTelemetry() throws {
        let device = Curve25519.KeyAgreement.PrivateKey()
        let hello = ClusterPeerHello(
            id: "id", name: "MacBook Pro",
            publicKey: device.publicKey.rawRepresentation)
        XCTAssertTrue(hello.isValid)
        let body = try JSONEncoder().encode(hello)
        let string = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(string.contains("chipWatts"))
        XCTAssertFalse(string.contains("cpuTemperature"))
        let frame = try XCTUnwrap(ClusterPacket.encode(type: ClusterPacket.hello, body: body))
        XCTAssertEqual(frame[4], ClusterPacket.hello)
        XCTAssertNil(ClusterPacket.encode(type: 99, body: body))
    }

    func testInvalidIdentityKeyIsRejected() {
        let hello = ClusterPeerHello(id: "id", name: "Mac", publicKey: Data([1, 2, 3]))
        XCTAssertFalse(hello.isValid)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try ClusterPairing.sessionKey(
            privateKey: privateKey, remotePublicKey: Data([1, 2, 3])))
    }
}
