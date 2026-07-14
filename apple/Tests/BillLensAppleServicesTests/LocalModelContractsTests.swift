import Foundation
import XCTest
@testable import BillLensAppleServices

final class LocalModelContractsTests: XCTestCase {
    func testBundledCatalogPinsExpectedModelsAndHuggingFaceRevisions() throws {
        let models = try LocalModelManager.bundledCatalog()
        XCTAssertEqual(models.map(\.modelId), [
            "qwen3.5-0.8b-q4_k_m",
            "qwen3.5-2b-q4_k_m",
        ])
        for model in models {
            XCTAssertEqual(model.downloadURL.scheme, "https")
            XCTAssertEqual(model.downloadURL.host, "huggingface.co")
            XCTAssertTrue(model.downloadURL.path.contains("/resolve/\(model.revision)/"))
            XCTAssertEqual(model.sha256.count, 64)
            XCTAssertGreaterThan(model.byteCount, 0)
        }
    }

    func testManifestRejectsUnknownFieldsAndUnknownSchema() throws {
        let unknownField = Data(
            #"{"schema_version":1,"models":[],"mirror":"https://example.com"}"#.utf8
        )
        XCTAssertThrowsError(try LocalModelManager.decodeCatalog(unknownField))

        let unknownSchema = Data(#"{"schema_version":2,"models":[]}"#.utf8)
        XCTAssertThrowsError(try LocalModelManager.decodeCatalog(unknownSchema))
    }

    func testPreviousInstalledRevisionRemainsValidUntilManualUpdate() throws {
        let descriptor = try XCTUnwrap(LocalModelManager.bundledCatalog().first)
        let previous = LocalModelInstalledState(
            revision: "1111111111111111111111111111111111111111",
            fileName: "previous.gguf",
            byteCount: 123,
            sha256: String(repeating: "a", count: 64),
            verifiedAt: Date()
        )
        XCTAssertNoThrow(
            try LocalModelManager.validateInstalledState(
                previous,
                modelId: descriptor.modelId,
                descriptor: descriptor
            )
        )
    }

    func testCurrentRevisionMustMatchBundledManifestExactly() throws {
        let descriptor = try XCTUnwrap(LocalModelManager.bundledCatalog().first)
        let invalid = LocalModelInstalledState(
            revision: descriptor.revision,
            fileName: descriptor.fileName,
            byteCount: descriptor.byteCount,
            sha256: String(repeating: "0", count: 64),
            verifiedAt: Date()
        )
        XCTAssertThrowsError(
            try LocalModelManager.validateInstalledState(
                invalid,
                modelId: descriptor.modelId,
                descriptor: descriptor
            )
        )
    }

    func testDownloadActivePhasesAreExhaustive() {
        XCTAssertTrue(LocalModelDownloadPhase.waitingForWiFi.isActive)
        XCTAssertTrue(LocalModelDownloadPhase.downloading.isActive)
        XCTAssertTrue(LocalModelDownloadPhase.verifying.isActive)
        XCTAssertFalse(LocalModelDownloadPhase.idle.isActive)
        XCTAssertFalse(LocalModelDownloadPhase.installed.isActive)
        XCTAssertFalse(LocalModelDownloadPhase.failed.isActive)
    }

    func testDownloadSessionConfigurationMatchesPlatformContract() {
        let configuration = LocalModelManager.makeDownloadSessionConfiguration()
        XCTAssertTrue(configuration.waitsForConnectivity)
        #if os(iOS)
        XCTAssertEqual(
            configuration.identifier,
            LocalModelManager.backgroundSessionIdentifier
        )
        XCTAssertFalse(configuration.allowsExpensiveNetworkAccess)
        XCTAssertFalse(configuration.allowsConstrainedNetworkAccess)
        #else
        XCTAssertNil(configuration.identifier)
        XCTAssertTrue(configuration.allowsExpensiveNetworkAccess)
        XCTAssertTrue(configuration.allowsConstrainedNetworkAccess)
        #endif
    }

    func testNetworkErrorsExposeDomainCodeAndUnderlyingCause() {
        let underlying = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ECONNRESET),
            userInfo: [NSLocalizedDescriptionKey: "connection reset"]
        )
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorUnknown,
            userInfo: [
                NSLocalizedDescriptionKey: "unknown error",
                NSUnderlyingErrorKey: underlying,
            ]
        )

        let description = LocalModelManager.diagnosticDescription(error)
        XCTAssertTrue(description.contains("domain=NSURLErrorDomain"))
        XCTAssertTrue(description.contains("code=-1"))
        XCTAssertTrue(description.contains("domain=NSPOSIXErrorDomain"))
        XCTAssertTrue(description.contains("code=\(ECONNRESET)"))
    }
}

final class LocalLlmFFIExportsTests: XCTestCase {
    func testOutputSummaryRejectsWhitespaceAndExposesOnlyStructuralMetadata() throws {
        let valid = LocalLlmOutputSummary(
            content: " \n[]\t",
            generatedTokenCount: 2,
            stopReason: .eog
        )
        XCTAssertEqual(valid.byteCount, 5)
        XCTAssertEqual(valid.trimmedByteCount, 2)
        XCTAssertEqual(valid.firstNonWhitespaceScalar, "U+005B")
        XCTAssertEqual(valid.lastNonWhitespaceScalar, "U+005D")
        XCTAssertNoThrow(try valid.validate())
        XCTAssertEqual(
            valid.logFields,
            "tokens=2 bytes=5 trimmed_bytes=2 first_non_whitespace=U+005B last_non_whitespace=U+005D stop=eog"
        )

        let whitespace = LocalLlmOutputSummary(
            content: " \n\t",
            generatedTokenCount: 3,
            stopReason: .eog
        )
        XCTAssertEqual(whitespace.firstNonWhitespaceScalar, "none")
        XCTAssertEqual(whitespace.lastNonWhitespaceScalar, "none")
        XCTAssertThrowsError(try whitespace.validate()) { error in
            XCTAssertTrue(error.localizedDescription.contains("未生成非空白内容"))
            XCTAssertFalse(error.localizedDescription.contains(" \n\t"))
        }
    }

    func testNullAndInvalidUTF8RequestsReturnExplicitErrors() throws {
        let nullResponse = try responseJSON(from: billlens_swift_local_llm_run(nil))
        XCTAssertEqual(nullResponse["status"] as? String, "error")
        XCTAssertEqual(nullResponse["code"] as? String, "invalid_runtime_response")

        var invalidUTF8: [CChar] = [-1, 0]
        let invalidResponse = try invalidUTF8.withUnsafeMutableBufferPointer { buffer in
            try responseJSON(from: billlens_swift_local_llm_run(buffer.baseAddress))
        }
        XCTAssertEqual(invalidResponse["status"] as? String, "error")
        XCTAssertEqual(invalidResponse["code"] as? String, "invalid_runtime_response")
    }

    func testInvalidJSONAndUnknownSchemaFailBeforeModelLoading() throws {
        let invalidJSON = try callRun("not-json")
        XCTAssertEqual(invalidJSON["code"] as? String, "invalid_runtime_request")

        let unknownSchema = try callRun(
            #"{"schema_version":2,"model_id":"test","system_prompt":"s","user_text":"u","grammar":"g","context_tokens":8192,"max_output_tokens":2048,"deadline_ms":45000}"#
        )
        XCTAssertEqual(unknownSchema["code"] as? String, "invalid_runtime_request")
    }

    func testBackgroundSuspensionRejectsNewInferenceUntilForegroundResume() throws {
        LocalLlmRuntime.shared.suspendForBackground()
        defer { LocalLlmRuntime.shared.resumeAfterBackground() }

        let response = try callRun(
            #"{"schema_version":1,"model_id":"test","system_prompt":"s","user_text":"u","grammar":"g","context_tokens":8192,"max_output_tokens":2048,"deadline_ms":45000}"#
        )
        XCTAssertEqual(response["status"] as? String, "error")
        XCTAssertEqual(response["code"] as? String, "app_backgrounded")
    }

    func testExportedStringAllocationAndFreeContractSurvivesStress() throws {
        let request = #"{"schema_version":2}"#
        for _ in 0..<1_000 {
            let response = try callRun(request)
            XCTAssertEqual(response["status"] as? String, "error")
        }
    }

    private func callRun(_ request: String) throws -> [String: Any] {
        try request.withCString { pointer in
            try responseJSON(from: billlens_swift_local_llm_run(pointer))
        }
    }

    private func responseJSON(
        from pointer: UnsafeMutablePointer<CChar>?
    ) throws -> [String: Any] {
        let responsePointer = try XCTUnwrap(pointer)
        defer { billlens_swift_local_llm_free_string(responsePointer) }
        let data = Data(String(cString: responsePointer).utf8)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
