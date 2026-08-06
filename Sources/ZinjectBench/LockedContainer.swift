import Foundation

/// Zinject's container as it was before Left-Right: one `NSRecursiveLock`
/// guarding both dictionaries, taken and released around every lookup.
///
/// Vendored here rather than imported so both designs can be measured in the
/// same process, on the same machine, in the same run. Only the parts the
/// benchmark exercises are reproduced, and the read path is instruction-for-
/// instruction the original: lock, one dictionary lookup, unlock.
final class LockedContainer: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var factories: [ObjectIdentifier: @Sendable (LockedContainer) -> Any] = [:]
    private var services: [ObjectIdentifier: Any] = [:]

    func register<Service>(
        _ type: Service.Type,
        factory: @Sendable @escaping (LockedContainer) -> Service
    ) {
        let key = ObjectIdentifier(type)
        lock.lock()
        factories[key] = { factory($0) }
        services[key] = nil
        lock.unlock()
    }

    func resolve<Service>(_ type: Service.Type) -> Service? {
        let key = ObjectIdentifier(type)

        lock.lock()
        if let cached = services[key] {
            lock.unlock()
            return cached as? Service
        }
        guard let factory = factories[key] else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let created = factory(self)

        lock.lock()
        if let cached = services[key] as? Service {
            lock.unlock()
            return cached
        }
        services[key] = created
        lock.unlock()

        return created as? Service
    }
}
