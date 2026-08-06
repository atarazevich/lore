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
/// **The rationale every other #135 site points back to.** A TCC-affecting
/// certificate change (a different team, or a transition involving ad-hoc)
/// makes macOS silently invalidate the Accessibility and Input Monitoring
/// grants — often while the toggles still *look* on and `AXIsProcessTrusted()`
/// still reads true (the "granted but Fn dead" incident, design §6). So the
/// change itself is the signal to guide a re-grant; the permission flags are
/// exactly the part that lies across it, and cannot raise it. Same-team cert
/// flips (dev ↔ release) share grants and are non-events (#140, `tccKey`).
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
    /// The tccKey transition last announced on the notch (#144). Separate from
    /// the baseline so the notch summon dedupes across launches while
    /// `migrationPending` stays derived: the panel row keeps warning until a
    /// real acknowledge, but the popup fires once per distinct transition.
    private static let summonKey = "signingMigrationSummoned"

    private let defaults: UserDefaults
    private let current: SigningIdentity.Info
    /// The baseline fingerprint the pending state was derived from, kept for
    /// `claimMigrationSummon()`'s transition marker. `nil` when nothing was
    /// persisted or the current signature is unreadable.
    private let seenFingerprint: String?

    /// True from launch until `acknowledge()`: the binary's identity differs
    /// from the one persisted at the previous launch. First-ever launch (no
    /// persisted value) is NOT a migration — the launch path just starts the
    /// record by acknowledging.
    private(set) var migrationPending: Bool

    /// Fired when `acknowledge()` closes a pending migration — never on the
    /// record-starting ack of a quiet launch. The notch's self-clear (#144)
    /// hangs off this: an identity summon on screen withdraws itself the moment
    /// the ledger has positive evidence the grants work.
    var onMigrationClosed: (() -> Void)?

    init(defaults: UserDefaults = .standard,
         current: SigningIdentity.Info = SigningIdentity.current()) {
        self.defaults = defaults
        self.current = current
        // An unreadable signature proves nothing, and no record means nothing to
        // differ from. Reading never writes: the record starts on an explicit
        // `acknowledge()` from the launch path.
        guard current.certKind != .unknown,
              let seen = defaults.string(forKey: Self.key) else {
            seenFingerprint = nil
            migrationPending = false
            return
        }
        seenFingerprint = seen
        migrationPending = Self.tccKey(seen) != Self.tccKey(Self.fingerprint(current))
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
        let closedAMigration = migrationPending
        migrationPending = false
        if closedAMigration { onMigrationClosed?() }
    }

    /// The notch summon's cross-launch dedup (#144): true at most once per
    /// distinct baseline→current tccKey transition, persisting the announced
    /// transition as the marker. A relaunch before the ack re-derives the same
    /// transition and stays silent; a genuinely new transition (baseline or
    /// current changed) claims again. Deliberately does NOT touch the baseline,
    /// so `migrationPending` — and the panel row's warning — survive relaunch
    /// until a real `acknowledge()`.
    func claimMigrationSummon() -> Bool {
        guard migrationPending, let seenFingerprint else { return false }
        let transition = "\(Self.tccKey(seenFingerprint))>\(Self.tccKey(Self.fingerprint(current)))"
        guard defaults.string(forKey: Self.summonKey) != transition else { return false }
        defaults.set(transition, forKey: Self.summonKey)
        return true
    }

    /// Cert kind and team in one string. The full pair stays the *stored* record
    /// (precise history, and old records parse unchanged); comparison goes
    /// through `tccKey`.
    private static func fingerprint(_ info: SigningIdentity.Info) -> String {
        "\(info.certKind.rawValue)|\(info.teamID ?? "")"
    }

    /// What a fingerprint means to TCC (#140). macOS keys Accessibility / Input
    /// Monitoring grants to the designated requirement, which `build.sh` pins to
    /// the *team* — so an Apple Development ↔ Developer ID flip within the same
    /// team keeps its grants and must not summon a re-grant walkthrough. Only a
    /// change that actually invalidates grants is a migration: a different team,
    /// or any transition involving ad-hoc (which has no team to key on).
    private static func tccKey(_ fingerprint: String) -> String {
        let parts = fingerprint.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return fingerprint }
        let (kind, team) = (parts[0], parts[1])
        let teamSigned = kind == SigningCertKind.appleDevelopment.rawValue
            || kind == SigningCertKind.developerID.rawValue
        return teamSigned && !team.isEmpty ? String(team) : fingerprint
    }
}
