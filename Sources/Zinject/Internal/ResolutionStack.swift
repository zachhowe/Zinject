import Foundation

/// The chain of services a single thread is part-way through resolving, used to
/// detect circular dependencies.
///
/// One stack per thread, shared by every container: nested resolves triggered
/// by a factory run on the thread that is running that factory, so a plain LIFO
/// with no synchronization is both sufficient and the cheapest thing available.
/// Entries are tagged with their container so two containers used from the same
/// thread cannot be mistaken for a cycle in one of them.
///
/// Depth is one to a few frames in practice, so the linear scans below beat the
/// allocation a per-container dictionary would cost.
final class ResolutionStack {
    private var entries: [(container: ObjectIdentifier, key: ServiceKey)] = []

    /// The service whose section this thread currently holds open, if any — see
    /// ``SectionGuard``.
    ///
    /// Lives here rather than in a thread-local of its own because pthread keys
    /// are a fixed per-process resource, and because the two are the same kind
    /// of fact: what this thread is in the middle of. Opening a second section
    /// is itself a contract violation and traps before arming one, so a single
    /// slot is enough — no depth counter is needed.
    ///
    /// The type it holds is the one named in the diagnostic, not the mechanism.
    /// `withResolvedRequired` is today's only opener; anything that later holds
    /// a section across user code records itself here the same way.
    var openSection: Any.Type?

    /// The stack belonging to the calling thread, created on first use and
    /// released when the thread exits.
    static var current: ResolutionStack {
        if let existing = pthread_getspecific(stackKey) {
            return Unmanaged<ResolutionStack>.fromOpaque(existing).takeUnretainedValue()
        }
        let stack = ResolutionStack()
        pthread_setspecific(stackKey, Unmanaged.passRetained(stack).toOpaque())
        return stack
    }

    /// Records that `container` has begun resolving `key`.
    ///
    /// - Returns: `nil` on success. If `key` is already in flight for this
    ///   container, nothing is pushed and the offending chain is returned,
    ///   ending with the repeated key.
    func push(container: ObjectIdentifier, key: ServiceKey) -> [ServiceKey]? {
        var chain: [ServiceKey] = []
        var isCycle = false
        for entry in entries where entry.container == container {
            chain.append(entry.key)
            if entry.key == key { isCycle = true }
        }

        guard !isCycle else {
            chain.append(key)
            return chain
        }

        entries.append((container, key))
        return nil
    }

    /// Removes this container's innermost in-flight resolution.
    ///
    /// Scans for the container rather than dropping the last entry outright,
    /// so that a resolve which spans two containers unwinds correctly.
    func pop(container: ObjectIdentifier) {
        guard let index = entries.lastIndex(where: { $0.container == container }) else {
            return
        }
        entries.remove(at: index)
    }
}

/// Thread-local storage for ``ResolutionStack``. Initialized exactly once via
/// Swift's `swift_once`-backed lazy global initialization.
private let stackKey: pthread_key_t = {
    var key = pthread_key_t()
    let status = pthread_key_create(&key) { value in
        // Balances the `passRetained` in `ResolutionStack.current`.
        //
        // Clearing the slot first is what keeps this destructor single-shot:
        // POSIX permits a key's destructor to be re-invoked while the value
        // stays non-NULL, and a second release here would over-release an
        // already-freed stack. Darwin, glibc, and musl all zero the slot
        // before calling; this pins the behavior rather than relying on it.
        pthread_setspecific(stackKey, nil)
        Unmanaged<ResolutionStack>.fromOpaque(value).release()
    }
    precondition(status == 0, "Zinject: pthread_key_create failed with status \(status)")
    return key
}()
