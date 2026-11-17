import XCTest
@testable import Aigo

final class PairingRecoveryTests: XCTestCase {
    @MainActor
    func testRepairSelectedPCReplacesClientAndToken() {
        let store = AppStore()
        let original = HostCredentials(addr: "127.0.0.1:1", fingerprint: String(repeating: "a", count: 64),
                                       token: "revoked-test-token", hostId: "pairing-test", hostName: "Test PC")
        store.installPairing(original)
        let oldClient = store.client
        let generation = store.clientGeneration
        var repaired = original
        repaired.token = "new-test-token"
        repaired.addr = "127.0.0.1:2"
        repaired.addrs = [repaired.addr, original.addr]
        store.installPairing(repaired)
        XCTAssertFalse(store.client === oldClient)
        XCTAssertEqual(store.client?.token, repaired.token)
        XCTAssertEqual(store.activeAddress, repaired.addr)
        XCTAssertGreaterThan(store.clientGeneration, generation)
        XCTAssertEqual(store.hosts.filter { $0.id == original.id }.count, 1)
        XCTAssertEqual(HostVault.load().first { $0.id == original.id }, repaired)
        store.forget(original.id)
    }

    @MainActor
    func testLegacyPairingAtDifferentAddressIsReplacedByCertificate() {
        let store = AppStore()
        let original = HostCredentials(addr: "127.0.0.1:1", fingerprint: String(repeating: "b", count: 64),
                                       token: "old", hostId: "", hostName: "Legacy PC")
        store.installPairing(original)
        var repaired = original
        repaired.addr = "127.0.0.1:2"
        repaired.hostId = "new-host-id"
        repaired.token = "new"
        store.installPairing(repaired)
        XCTAssertEqual(store.hosts.filter { $0.fingerprint == original.fingerprint }.count, 1)
        XCTAssertEqual(store.activeHostID, repaired.id)
        store.forget(repaired.id)
    }

    func testPairingErrorsDoNotClaimRevocation() {
        for status in [401, 409, 429] {
            let error = APIError.from(status: status, data: Data(), pairing: true)
            XCTAssertFalse(error.needsRepair)
            XCTAssertFalse(error.message.contains("removed"))
        }
        XCTAssertTrue(APIError.from(status: 401, data: Data()).needsRepair)
    }
}
