import Foundation
import Security
import XCTest
@testable import BillLensAppleServices

final class MicrosoftAuthTests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636Example() {
        // RFC 7636 附录 B 的示例。
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCERequest.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRandomValuesAreURLSafeAndLongEnough() {
        let request = PKCERequest()
        XCTAssertGreaterThanOrEqual(request.verifier.count, 43)
        XCTAssertNil(request.verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(PKCERequest().state, request.state)
    }

    func testAuthorizeURLRequestsOnlyReadOnlyMailForPersonalAccounts() throws {
        let request = PKCERequest(verifier: "v", state: "s")
        let url = request.authorizeURL(config: MicrosoftOAuthConfig(clientID: "client-123"))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize"))
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        ).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["client_id"], "client-123")
        XCTAssertEqual(items["scope"], "offline_access Mail.Read User.Read")
        XCTAssertEqual(items["redirect_uri"], "billumi-auth://oauth")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], PKCERequest.challenge(for: "v"))
        XCTAssertEqual(items["state"], "s")
    }

    func testCallbackRequiresMatchingStateAndMapsErrors() throws {
        let request = PKCERequest(verifier: "v", state: "expected")
        XCTAssertEqual(
            try request.authorizationCode(from: URL(string: "billumi-auth://oauth?code=abc&state=expected")!),
            "abc"
        )
        XCTAssertThrowsError(try request.authorizationCode(from: URL(string: "billumi-auth://oauth?code=abc&state=forged")!)) {
            XCTAssertEqual($0 as? MicrosoftAuthError, .stateMismatch)
        }
        XCTAssertThrowsError(try request.authorizationCode(from: URL(string: "billumi-auth://oauth?state=expected")!)) {
            XCTAssertEqual($0 as? MicrosoftAuthError, .missingCode)
        }
        XCTAssertThrowsError(try request.authorizationCode(from: URL(string: "billumi-auth://oauth?error=access_denied&state=expected")!)) {
            XCTAssertEqual($0 as? MicrosoftAuthError, .cancelled)
        }
    }

    func testFormBodyPercentEncodesReservedCharacters() {
        let body = String(decoding: MicrosoftAuthService.formBody([
            "scope": "offline_access Mail.Read",
            "redirect_uri": "billumi-auth://oauth",
            "code": "a+b/c=",
        ]), as: UTF8.self)
        XCTAssertEqual(
            body,
            "code=a%2Bb%2Fc%3D&redirect_uri=billumi-auth%3A%2F%2Foauth&scope=offline_access%20Mail.Read"
        )
    }

    func testTokenStoreRoundTripAndDelete() throws {
        let store = MicrosoftTokenStore(service: "com.shendongchun.BillLensApple.tests.\(UUID().uuidString)")
        defer { store.delete() }
        do {
            try store.save(.init(accountAddress: "a@hotmail.com", refreshToken: "r1"))
        } catch let error as NSError where error.code == Int(errSecMissingEntitlement) {
            throw XCTSkip("测试进程没有钥匙串权限")
        }
        XCTAssertEqual(store.load(), .init(accountAddress: "a@hotmail.com", refreshToken: "r1"))
        try store.save(.init(accountAddress: "a@hotmail.com", refreshToken: "r2"))
        XCTAssertEqual(store.load()?.refreshToken, "r2")
        store.delete()
        XCTAssertNil(store.load())
    }

    func testICloudCredentialStoreRoundTripAndDelete() throws {
        let store = ICloudMailCredentialStore(service: "com.shendongchun.BillLensApple.tests.\(UUID().uuidString)")
        defer { store.delete() }
        do {
            try store.save(.init(accountAddress: "a@icloud.com", appPassword: "abcd-efgh-ijkl-mnop"))
        } catch let error as NSError where error.code == Int(errSecMissingEntitlement) {
            throw XCTSkip("测试进程没有钥匙串权限")
        }
        XCTAssertEqual(store.connectedAddress, "a@icloud.com")
        XCTAssertEqual(store.load()?.appPassword, "abcd-efgh-ijkl-mnop")
        store.delete()
        XCTAssertNil(store.load())
    }

    func testUnconfiguredClientIDIsTreatedAsMissing() {
        XCTAssertNil(MicrosoftOAuthConfig.fromBundle, "测试宿主没有配置 Client ID")
    }
}
