import Foundation

/// Whether this process is a unit-test run.
///
/// Several subsystems must not touch the user's real state from a test — the
/// Keychain (a prompt against the user's actual secrets), the settings store,
/// and the diagnostic event ring. They all asked the same question in the same
/// way; it is asked in exactly one place now.
enum RuntimeEnvironment {
    static let isRunningUnitTests = NSClassFromString("XCTestCase") != nil
}
