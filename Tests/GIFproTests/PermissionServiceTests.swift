import Foundation
import Testing
@testable import GIFpro

@Suite("Screen capture permissions")
struct PermissionServiceTests {
    @Test("Existing permission skips the system request")
    func existingPermissionSkipsRequest() {
        let checker = FakeScreenCapturePermissionChecker(preflightResults: [true])
        let service = PermissionService(checker: checker)

        #expect(service.requestAccessIfNeeded())
        #expect(checker.preflightCallCount == 1)
        #expect(checker.requestCallCount == 0)
    }

    @Test("Missing permission requests access")
    func missingPermissionRequestsAccess() {
        let checker = FakeScreenCapturePermissionChecker(
            preflightResults: [false],
            requestResult: true
        )
        let service = PermissionService(checker: checker)

        #expect(service.requestAccessIfNeeded())
        #expect(checker.requestCallCount == 1)
    }

    @Test("Denied permission can open Screen Recording settings")
    func deniedPermissionCanOpenSettings() throws {
        let checker = FakeScreenCapturePermissionChecker(
            preflightResults: [false],
            requestResult: false
        )
        let service = PermissionService(checker: checker)

        #expect(!service.requestAccessIfNeeded())
        try service.openSettings()
        #expect(checker.openSettingsCallCount == 1)
    }

    @Test("Becoming active rechecks without requesting again")
    func becomingActiveRechecksWithoutRequesting() {
        let checker = FakeScreenCapturePermissionChecker(
            preflightResults: [false, true],
            requestResult: false
        )
        let service = PermissionService(checker: checker)

        #expect(!service.requestAccessIfNeeded())
        #expect(service.recheckAccess())
        #expect(checker.preflightCallCount == 2)
        #expect(checker.requestCallCount == 1)
    }

    @Test("System adapter opens the Screen Recording privacy URL")
    func systemAdapterOpensExpectedURL() throws {
        var openedURL: URL?
        let adapter = SystemScreenCapturePermissionChecker(
            preflight: { false },
            request: { false },
            openURL: {
                openedURL = $0
                return true
            }
        )

        try adapter.openSettings()

        #expect(openedURL?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @Test("System adapter reports settings launch failure")
    func systemAdapterReportsOpenFailure() {
        let adapter = SystemScreenCapturePermissionChecker(
            preflight: { false },
            request: { false },
            openURL: { _ in false }
        )

        #expect(throws: PermissionServiceError.settingsCouldNotOpen) {
            try adapter.openSettings()
        }
    }
}

private final class FakeScreenCapturePermissionChecker: ScreenCapturePermissionChecking {
    private var preflightResults: [Bool]
    private let requestResult: Bool
    private(set) var preflightCallCount = 0
    private(set) var requestCallCount = 0
    private(set) var openSettingsCallCount = 0

    init(preflightResults: [Bool], requestResult: Bool = false) {
        self.preflightResults = preflightResults
        self.requestResult = requestResult
    }

    func preflight() -> Bool {
        defer { preflightCallCount += 1 }
        return preflightResults.removeFirst()
    }

    func request() -> Bool {
        requestCallCount += 1
        return requestResult
    }

    func openSettings() throws {
        openSettingsCallCount += 1
    }
}
