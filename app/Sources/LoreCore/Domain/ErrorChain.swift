import Foundation

extension Error {
    /// This error and the ones beneath it (`NSUnderlyingErrorKey`), outermost
    /// first. Foundation reports a file failure as a Cocoa error with the POSIX
    /// one underneath, so a classifier reads the whole chain, not the top.
    public var underlyingChain: [NSError] {
        let error = self as NSError
        return [error] + ((error.userInfo[NSUnderlyingErrorKey] as? NSError)?.underlyingChain ?? [])
    }
}
