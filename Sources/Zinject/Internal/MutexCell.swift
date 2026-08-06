import Foundation

/// The minimum a mutex has to do to back a ``MutexCell``.
///
/// A protocol rather than two copies of the cell because `MutexCell` takes it as
/// a generic parameter, not an existential: within the module the compiler
/// specializes each instantiation, so `lock()` and `unlock()` are direct calls
/// with no witness-table indirection. That matters here — the whole reason these
/// types exist is to be timed against each other, and a dispatch cost paid by
/// one arm and not the other would be indistinguishable from a design
/// difference.
@usableFromInline
protocol Locking: AnyObject, Sendable {
    /// Whether the same thread can take this lock twice.
    ///
    /// Only a recursive lock can let a write nested inside a read *succeed*, and
    /// succeeding is the dangerous outcome — see ``MutexCell/readDepth``. A
    /// static constant on a concrete type rather than an instance property, so
    /// that the check it guards folds away entirely for the arm that cannot have
    /// the problem.
    static var isRecursive: Bool { get }

    init()
    func lock()
    func unlock()
}

/// `NSRecursiveLock`, exactly as `Container` used it before the Left-Right
/// rewrite. The historical baseline, kept honest by being the same lock type.
@usableFromInline
final class RecursiveLock: Locking {
    @usableFromInline
    static let isRecursive = true

    @usableFromInline
    let mutex = NSRecursiveLock()

    @usableFromInline
    init() {}

    @inlinable @inline(__always) func lock() { mutex.lock() }
    @inlinable @inline(__always) func unlock() { mutex.unlock() }
}

#if canImport(Darwin)
/// `os_unfair_lock`, the cheapest mutex Darwin offers.
///
/// The lock lives behind a pointer because `os_unfair_lock` must never be copied
/// or moved, and Swift gives no guarantee that a stored struct property stays
/// put. `@unchecked` because that pointer is not `Sendable`; it is never
/// reassigned, and the memory it addresses is a lock, whose entire job is to be
/// touched from several threads.
@usableFromInline
final class UnfairLock: Locking, @unchecked Sendable {
    @usableFromInline
    static let isRecursive = false

    @usableFromInline
    let mutex: UnsafeMutablePointer<os_unfair_lock>

    @usableFromInline
    init() {
        mutex = .allocate(capacity: 1)
        mutex.initialize(to: os_unfair_lock())
    }

    deinit {
        mutex.deinitialize(count: 1)
        mutex.deallocate()
    }

    @inlinable @inline(__always) func lock() { os_unfair_lock_lock(mutex) }
    @inlinable @inline(__always) func unlock() { os_unfair_lock_unlock(mutex) }
}
#else
/// `os_unfair_lock` is Darwin-only; `NSLock` is the closest non-recursive
/// equivalent elsewhere. The strategy keeps its name so behavior and tests stay
/// portable, but the numbers are not comparable across platforms.
@usableFromInline
final class UnfairLock: Locking {
    @usableFromInline
    static let isRecursive = false

    @usableFromInline
    let mutex = NSLock()

    init() {}

    @inline(__always) func lock() { mutex.lock() }
    @inline(__always) func unlock() { mutex.unlock() }
}
#endif

/// A ``StateCell`` that serializes every access behind one mutex.
///
/// Readers and writers contend with each other, which is the entire point of
/// comparing it against ``LeftRight``: it is what the container did before, and
/// what it would still do if the wait-free read path turns out not to be worth
/// its cost.
@usableFromInline
final class MutexCell<Lock: Locking, Value>: StateCell, @unchecked Sendable {
    @usableFromInline
    let mutex = Lock()

    /// The state lives behind a pointer, mirroring ``LeftRight/instances``. A
    /// stored property would work too, but handing `body` an `UnsafePointer` to
    /// one means taking `&self.value` inside the critical section, which drags
    /// in exclusivity enforcement for no benefit.
    @usableFromInline
    let storage: UnsafeMutablePointer<Value>

    /// Read sections the thread holding ``mutex`` has open.
    ///
    /// Only ever touched while the lock is held, so no atomics are needed, and a
    /// non-zero value seen inside ``write(_:)`` necessarily belongs to the
    /// calling thread — no other thread could have got past the lock.
    ///
    /// Behind a pointer for the reason ``storage`` is: a stored `var` on a class
    /// is subject to *dynamic* exclusivity enforcement, and mutating one twice
    /// per read cost this arm 18% of its single-threaded resolve. A pointer
    /// write is not an access the runtime tracks.
    ///
    /// It exists for one arm. Under a recursive lock a write nested inside a
    /// read *succeeds*, and mutating state a reader is still holding a pointer
    /// to is the same use-after-free the container's borrow contract exists to
    /// prevent; the failure is silent, so it has to be caught in release builds
    /// too. ``UnfairLock`` cannot reach that state — it aborts inside
    /// `os_unfair_lock_lock`, which is loud enough and happens before any check
    /// here could run — so the tracking is guarded on ``Locking/isRecursive``
    /// and disappears from that arm along with the branch.
    @usableFromInline
    let readDepth: UnsafeMutablePointer<Int>

    @usableFromInline
    init(_ initial: Value) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: initial)
        readDepth = .allocate(capacity: 1)
        readDepth.initialize(to: 0)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
        readDepth.deinitialize(count: 1)
        readDepth.deallocate()
    }

    @inlinable
    func read<R>(_ body: (UnsafePointer<Value>) -> R) -> R {
        mutex.lock()
        if Lock.isRecursive { readDepth.pointee += 1 }
        defer {
            if Lock.isRecursive { readDepth.pointee -= 1 }
            mutex.unlock()
        }
        return body(UnsafePointer(storage))
    }

    /// See ``StateCell/read(_:)-throwing``. `defer` already unlocks on an
    /// unwind, so this is the same body with `try` in it.
    @inlinable
    func read<R>(_ body: (UnsafePointer<Value>) throws -> R) rethrows -> R {
        mutex.lock()
        if Lock.isRecursive { readDepth.pointee += 1 }
        defer {
            if Lock.isRecursive { readDepth.pointee -= 1 }
            mutex.unlock()
        }
        return try body(UnsafePointer(storage))
    }

    @usableFromInline
    @discardableResult
    func write<R>(_ body: (inout Value) -> R) -> R {
        mutex.lock()
        defer { mutex.unlock() }
        // See ``readDepth``: this is the one strategy where the mistake would
        // otherwise go through, and what it goes through to is a mutation of
        // state the enclosing read is still holding a pointer to.
        if Lock.isRecursive, readDepth.pointee != 0 {
            StateCellContract.reentrantWrite()
        }
        return body(&storage.pointee)
    }
}
