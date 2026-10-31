import Foundation
import LoreCore

/// Why a file or folder could not be opened, in the two cases worth telling
/// apart: it isn't there, or macOS won't allow it. Shared by `lore transcribe`
/// (#254) and the iPhone notes folder (#309).
enum FileOpenFailure: Equatable {
    case missing
    case notPermitted
    case other

    init(errno code: Int32) {
        switch code {
        case ENOENT, ENOTDIR: self = .missing
        case EACCES, EPERM: self = .notPermitted
        default: self = .other
        }
    }

    /// From Foundation's error: Cocoa's own codes first, then the POSIX error
    /// underneath them.
    init(_ error: Error) {
        for error in error.underlyingChain {
            switch (error.domain, CocoaError.Code(rawValue: error.code)) {
            case (NSCocoaErrorDomain, .fileReadNoSuchFile), (NSCocoaErrorDomain, .fileNoSuchFile):
                self = .missing; return
            case (NSCocoaErrorDomain, .fileReadNoPermission):
                self = .notPermitted; return
            case (NSPOSIXErrorDomain, _):
                self.init(errno: Int32(error.code)); return
            default: continue
            }
        }
        self = .other
    }
}
