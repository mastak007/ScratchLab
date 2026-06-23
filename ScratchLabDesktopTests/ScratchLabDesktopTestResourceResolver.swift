import Foundation
import XCTest

/// Shared helper that resolves the host ScratchLab.app bundle and its Resources
/// directory from the running test process, regardless of whether tests execute
/// via `xcodebuild test` (TEST_HOST = ScratchLab.app) or via `xcrun xctest`
/// (Bundle.main = xctest bundle).
///
/// Resolution order:
/// 1. `Bundle.main` — when TEST_HOST is set, Bundle.main *is* the app bundle.
///    Verify by checking for a known sentinel resource (`Coach.usdz`).
/// 2. Walk upward from the xctest bundle:
///    `.../ScratchLab.app/Contents/PlugIns/ScratchLabDesktopTests.xctest`
///    → `.../ScratchLab.app`
///    Verify with the same sentinel.
///
/// The helper returns nil only when no app bundle can be found containing the
/// sentinel — callers should XCTSkip / guard-let / try XCTUnwrap accordingly
/// for tests that genuinely require app-bundle resources.
final class ScratchLabDesktopTestResourceResolver {
    private init() {}

    /// Known resource that must exist in the app bundle's Resources directory.
    /// Coach.usdz is bundled for both iOS and macOS targets and is large enough
    /// that it won't be accidentally present in a test-only bundle.
    private static let sentinelResourceName = "Coach"
    private static let sentinelResourceExt = "usdz"

    // MARK: - App bundle

    /// The host ScratchLab.app bundle, resolved from either the test host or
    /// the xctest bundle path. Returns nil when no app bundle containing
    /// `Coach.usdz` can be found.
    static var appBundle: Bundle? {
        // Path 1: Bundle.main is the app bundle when TEST_HOST is set.
        if let url = Bundle.main.url(forResource: sentinelResourceName,
                                      withExtension: sentinelResourceExt) {
            // Verify the URL lives under an .app bundle.
            let path = url.path
            if path.contains(".app/") {
                return Bundle.main
            }
        }

        // Path 2: Walk up from the xctest bundle.
        // xctest bundle URL: .../ScratchLab.app/Contents/PlugIns/ScratchLabDesktopTests.xctest
        let testBundle = Bundle(for: ScratchLabDesktopTestResourceResolver.self)
        let appURL = testBundle.bundleURL
            .deletingLastPathComponent()  // PlugIns
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // ScratchLab.app
        guard appURL.pathExtension == "app" else { return nil }
        guard let candidate = Bundle(url: appURL) else { return nil }
        guard candidate.url(forResource: sentinelResourceName,
                            withExtension: sentinelResourceExt) != nil else {
            return nil
        }
        return candidate
    }

    // MARK: - Resources URL

    /// The app bundle's Resources directory URL (flat resource root), resolved
    /// via the same strategy. Equivalent to `appBundle?.resourceURL`.
    static var appResourcesURL: URL? {
        return appBundle?.resourceURL
    }

    /// Returns an app Resources URL for use in tests that require bundled
    /// resources. Calls XCTSkip (test marked skipped) when the app bundle
    /// can't be resolved; callers that want a hard failure should use
    /// `XCTUnwrap` instead.
    static func requiredAppResourcesURL(file: StaticString = #filePath,
                                         line: UInt = #line) -> URL? {
        guard let url = appResourcesURL else {
            XCTSkip("App Resources not available — running without test host and xctest path walk failed",
                     file: file, line: line)
            return nil
        }
        return url
    }
}
