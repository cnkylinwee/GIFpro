import AppKit
import CoreGraphics
import Foundation

protocol ScreenCapturePermissionChecking {
    func preflight() -> Bool
    func request() -> Bool
    func openSettings() throws
}

enum PermissionServiceError: Error, Equatable {
    case settingsCouldNotOpen
}

final class PermissionService {
    private let checker: any ScreenCapturePermissionChecking

    init(checker: any ScreenCapturePermissionChecking = SystemScreenCapturePermissionChecker()) {
        self.checker = checker
    }

    func requestAccessIfNeeded() -> Bool {
        checker.preflight() || checker.request()
    }

    func recheckAccess() -> Bool {
        checker.preflight()
    }

    func openSettings() throws {
        try checker.openSettings()
    }
}

final class SystemScreenCapturePermissionChecker: ScreenCapturePermissionChecking {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    private let preflightAccess: () -> Bool
    private let requestAccess: () -> Bool
    private let openURL: (URL) -> Bool

    init(
        preflight: @escaping () -> Bool = CGPreflightScreenCaptureAccess,
        request: @escaping () -> Bool = CGRequestScreenCaptureAccess,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        preflightAccess = preflight
        requestAccess = request
        self.openURL = openURL
    }

    func preflight() -> Bool {
        preflightAccess()
    }

    func request() -> Bool {
        requestAccess()
    }

    func openSettings() throws {
        guard openURL(Self.settingsURL) else {
            throw PermissionServiceError.settingsCouldNotOpen
        }
    }
}
