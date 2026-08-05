import Foundation
import Security

/// The running binary's code signature, read via `SecCodeCopySigningInformation`.
///
/// Surfaces the certificate class and team so a remote user's build is
/// unambiguous — the "granted but Fn dead" incident (design §6) turned on
/// exactly whether a certificate change had silently invalidated TCC grants.
/// Read-only and cheap.
enum SigningIdentity {
    struct Info: Equatable, Sendable {
        let certKind: SigningCertKind
        /// Team identifier (e.g. `M4JMM4ZQDJ`). Identifies the build, not the
        /// user; shown in the panel, kept out of the snapshot to stay minimal.
        let teamID: String?
    }

    static func current() -> Info {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return Info(certKind: .unknown, teamID: nil)
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return Info(certKind: .unknown, teamID: nil)
        }
        var infoCF: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else {
            return Info(certKind: .unknown, teamID: nil)
        }
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        return Info(certKind: classify(info), teamID: teamID)
    }

    /// The leaf certificate's common name distinguishes the three build kinds;
    /// no certificates at all means ad-hoc (`codesign --sign -`), which is what
    /// resets permissions each launch.
    private static func classify(_ info: [String: Any]) -> SigningCertKind {
        guard let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else {
            return .adHoc
        }
        var cn: CFString?
        SecCertificateCopyCommonName(leaf, &cn)
        let name = (cn as String?) ?? ""
        if name.hasPrefix("Developer ID Application") { return .developerID }
        if name.hasPrefix("Apple Development") || name.hasPrefix("Mac Developer") {
            return .appleDevelopment
        }
        return .unknown
    }
}

/// Persists the identity seen at the last launch and detects a change (#135).
///
/// **The rationale every other #135 site points back to.** A certificate change
/// (free Apple Development → Developer ID at v3.0.0, or any future cert event)
/// makes macOS silently invalidate the Accessibility and Input Monitoring
/// grants — often while the toggles still *look* on and `AXIsProcessTrusted()`
/// still reads true (the "granted but Fn dead" incident, design §6). So the
/// change itself is the signal to guide a re-grant; the permission flags are
/// exactly the part that lies across it, and cannot raise it.
///
/// For the same reason the flow closes only on the one fact that cannot lie: a
/// key-down that actually reached Lore's own tap
/// (`TapLiveness.hasReceivedKeyDown`), which `HealthMonitor.refresh` feeds to
/// `acknowledge()`.
///
/// The pending state is *derived* (persisted identity ≠ current identity), not
/// stored, so it survives relaunches until `acknowledge()` writes the new
/// identity. Team + cert kind identify the build, not the user — UserDefaults
/// is the right home; this is not a secret.
@MainActor
final class SigningIdentityLedger {
    private static let key = "signingIdentityLastSeen"

    private let defaults: UserDefaults
    private let current: SigningIdentity.Info

    /// True from launch until `acknowledge()`: the binary's identity differs
    /// from the one persisted at the previous launch. First-ever launch (no
    /// persisted value) is NOT a migration — the launch path just starts the
    /// record by acknowledging.
    private(set) var migrationPending: Bool

    init(defaults: UserDefaults = .standard,
         current: SigningIdentity.Info = SigningIdentity.current()) {
        self.defaults = defaults
        self.current = current
        // An unreadable signature proves nothing, and no record means nothing to
        // differ from. Reading never writes: the record starts on an explicit
        // `acknowledge()` from the launch path.
        guard current.certKind != .unknown,
              let seen = defaults.string(forKey: Self.key) else {
            migrationPending = false
            return
        }
        migrationPending = seen != Self.fingerprint(current)
    }

    /// Make the current identity the record: called on positive evidence the
    /// re-granted permissions work (`HealthMonitor.refresh`), and by the launch
    /// path when there is nothing pending — which is what starts the record on a
    /// first-ever launch.
    func acknowledge() {
        // An `unknown` reading must never clobber a good record: the next
        // readable launch still has to compare against the real previous one.
        guard current.certKind != .unknown else { return }
        defaults.set(Self.fingerprint(current), forKey: Self.key)
        migrationPending = false
    }

    /// Cert kind and team in one string, so "did the identity change" is one
    /// read and one `==`. An ad-hoc build has no team; the empty half is part of
    /// the fingerprint and round-trips like any other.
    private static func fingerprint(_ info: SigningIdentity.Info) -> String {
        "\(info.certKind.rawValue)|\(info.teamID ?? "")"
    }
}
