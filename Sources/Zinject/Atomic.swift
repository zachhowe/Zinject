import Foundation

@propertyWrapper
final class Atomic<T>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var underlyingValue: T

    init(wrappedValue: T) {
        underlyingValue = wrappedValue
    }

    var wrappedValue: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return underlyingValue
        }
        _modify {
            lock.lock()
            defer { lock.unlock() }
            yield &underlyingValue
        }
    }
}
