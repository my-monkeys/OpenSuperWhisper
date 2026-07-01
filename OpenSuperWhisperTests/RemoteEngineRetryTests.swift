import XCTest
@testable import OpenSuperWhisper

/// The Remote engine retries only *transient* failures — a self-hosted endpoint
/// behind a reverse proxy can briefly return 405/5xx while it redeploys, and a
/// network blip is momentary — while never retrying real client errors (bad
/// request, auth, a genuine JSON 405) or a bad URL. This guards that
/// classification so a long dictation isn't lost to a one-off server bounce,
/// while a real error still fails fast.
final class RemoteEngineRetryTests: XCTestCase {

    // MARK: - HTTP status classification

    func testRetriesServerAndThrottleStatuses() {
        for status in [408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(RemoteEngine.isRetryable(status: status, body: ""),
                          "\(status) should be retryable")
        }
    }

    func testDoesNotRetryPlainClientErrors() {
        for status in [400, 401, 403, 404, 422] {
            XCTAssertFalse(RemoteEngine.isRetryable(status: status, body: "{\"error\":\"nope\"}"),
                           "\(status) should not be retryable")
        }
    }

    func testRetries405OnlyWhenItIsAProxyHTMLPage() {
        // The static "405 Not Allowed" page nginx serves during a redeploy — transient.
        let nginx405 = "<html><head><title>405 Not Allowed</title></head><body>"
            + "<center><h1>405 Not Allowed</h1></center><hr><center>nginx/1.31.2</center></body></html>"
        XCTAssertTrue(RemoteEngine.isRetryable(status: 405, body: nginx405))
        // A real JSON-API 405 is a genuine method error — do not retry.
        XCTAssertFalse(RemoteEngine.isRetryable(status: 405,
                                                body: "{\"error\":{\"message\":\"Method Not Allowed\"}}"))
    }

    // MARK: - Transport-error classification

    func testRetriesTransientTransportErrors() {
        let codes: [URLError.Code] = [.timedOut, .cannotConnectToHost, .cannotFindHost,
                                      .dnsLookupFailed, .networkConnectionLost,
                                      .notConnectedToInternet, .resourceUnavailable,
                                      .badServerResponse]
        for code in codes {
            XCTAssertTrue(RemoteEngine.isRetryable(URLError(code)), "\(code) should be retryable")
        }
    }

    func testDoesNotRetryNonTransientTransportErrors() {
        let codes: [URLError.Code] = [.badURL, .unsupportedURL, .cancelled, .userAuthenticationRequired]
        for code in codes {
            XCTAssertFalse(RemoteEngine.isRetryable(URLError(code)), "\(code) should not be retryable")
        }
    }

    // MARK: - Backoff + attempt budget

    func testBackoffGrowsAfterFirstAttempt() {
        XCTAssertEqual(RemoteEngine.backoffNanos(afterAttempt: 1), 500_000_000)
        XCTAssertEqual(RemoteEngine.backoffNanos(afterAttempt: 2), 1_500_000_000)
    }

    func testAttemptBudgetIsOneTryPlusTwoRetries() {
        XCTAssertEqual(RemoteEngine.maxAttempts, 3)
    }
}
