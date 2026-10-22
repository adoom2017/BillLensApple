import Foundation
import XCTest
@testable import BillLensShared

final class RustBridgeContractsTests: XCTestCase {
    func testNullCloudConfigurationIsAValidSuccessfulResult() throws {
        let data = Data(#"{"ok":true,"data":null,"error":null}"#.utf8)
        let envelope = try JSONDecoder().decode(EngineEnvelope<LlmConfigItem?>.self, from: data)
        guard case .some(.none) = envelope.data else {
            return XCTFail("Expected a successful optional nil result")
        }
        XCTAssertTrue(envelope.ok)
    }

    func testMissingDataOrNullRequiredDataFails() {
        let missing = Data(#"{"ok":true,"error":null}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(EngineEnvelope<LlmConfigItem?>.self, from: missing))
        let null = Data(#"{"ok":true,"data":null,"error":null}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(EngineEnvelope<LlmConfigItem>.self, from: null))
    }

    func testEngineFailurePreservesMessageWithoutDecodingSuccessData() throws {
        let data = Data(#"{"ok":false,"data":null,"error":"invalid request: unknown action"}"#.utf8)
        let envelope = try JSONDecoder().decode(EngineEnvelope<LlmConfigItem>.self, from: data)
        XCTAssertFalse(envelope.ok)
        XCTAssertNil(envelope.data)
        XCTAssertEqual(envelope.error, "invalid request: unknown action")
    }
}
