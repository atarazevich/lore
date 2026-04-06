import Foundation

/// Simple thread-safe float holder for audio level.
final class AudioLevel: @unchecked Sendable {
    private var _value: Float = 0
    private let lock = NSLock()

    var value: Float {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Simple thread-safe optional string holder.
final class SyncString: @unchecked Sendable {
    private var _value: String?
    private let lock = NSLock()

    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Simple thread-safe double holder.
final class SyncDouble: @unchecked Sendable {
    private var _value: Double = 0
    private let lock = NSLock()

    var value: Double {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    func add(_ delta: Double) {
        lock.withLock { _value += delta }
    }
}

/// Simple thread-safe bool holder.
final class SyncBool: @unchecked Sendable {
    private var _value = false
    private let lock = NSLock()

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Simple thread-safe optional Date holder.
final class SyncOptionalDate: @unchecked Sendable {
    private var _value: Date?
    private let lock = NSLock()

    var value: Date? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
