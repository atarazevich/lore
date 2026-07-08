import Foundation
import Security

/// The running binary's code signature, read via `SecCodeCopySigningInformation`.
///
/// Surfaces the certificate class and team so a remote user's build is
/// unambiguous — the "granted but Fn dead" incident (design §13) turned on
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
