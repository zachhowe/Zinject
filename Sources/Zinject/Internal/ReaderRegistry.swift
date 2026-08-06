import Atomics
import Foundation

/// Assigns each thread a small, stable integer so that concurrency primitives
/// can give it a private, cache-line-isolated slot in a shared array.
///
/// IDs are process-global rather than per-container: pthread keys are a scarce
/// resource (`PTHREAD_KEYS_MAX`), so allocating one per `Container` would not
/// survive a program that builds many containers. One key hands out one ID per
/// thread, and every `LeftRight` instance indexes its own slot array with it.
///
/// IDs are recycled when a thread exits. A thread that arrives after all
/// `capacity` IDs are taken is given ``invalidID`` permanently and falls back
/// to a lock-based slow path — correct, just not wait-free.
@usableFromInline
enum ReaderRegistry {
    /// Number of threads that can hold a private slot at once.
    ///
    /// Sizing note: every `LeftRight` allocates
    /// `2 * capacity * cacheLineSize` bytes of read-indicator storage (16 KiB
    /// at these constants), so raising this raises the per-container fixed
    /// cost. 64 comfortably covers a machine's worth of concurrent resolvers.
    ///
    /// It is also exactly `UInt64.bitWidth`, which ``allocatedSlotMask()``
    /// depends on. Raising it means widening that mask to more than one word.
    @usableFromInline
    static let capacity = 64

    /// Returned when no slot is available; routes the caller to a slow path.
    @usableFromInline
    static let invalidID = -1

    /// Slot IDs are stored in thread-local storage biased by one, because a
    /// `pthread_getspecific` of `NULL` is indistinguishable from a stored zero.
    @usableFromInline
    static let idBias = 1

    /// Distinct from any biased ID, so a thread that loses the race for a slot
    /// records that fact once instead of re-entering the allocator on every
    /// read.
    @usableFromInline
    static let exhaustedMarker = UInt(Int.max)

    private static let allocationLock = NSLock()
    private static nonisolated(unsafe) var availableIDs: [Int] = Array((0 ..< capacity).reversed())

    /// Bit *k* is set for as long as some live thread holds reader ID *k*.
    ///
    /// Maintained under ``allocationLock`` — allocation and recycling are both
    /// once-per-thread events — but published atomically, because a `LeftRight`
    /// writer reads it on every drain and must not take a lock to do so.
    ///
    /// This is what lets a drain scan the slots that are actually in use rather
    /// than all ``capacity`` of them, which is otherwise 64 cold cache lines
    /// twice per write. It tracks the live set rather than a high-water mark on
    /// purpose: a thread pool that spikes and quiesces gives its slots back, and
    /// a mark that only ever grew would keep every later write paying for the
    /// peak.
    private static let allocatedSlots = ManagedAtomic<UInt64>(0)

    /// The reader IDs currently held by live threads, as a bit set.
    ///
    /// Sequentially consistent, and load-bearing at that strength: see the
    /// argument in `LeftRight.waitUntilDrained`, which is the only caller.
    static func allocatedSlotMask() -> UInt64 {
        allocatedSlots.load(ordering: .sequentiallyConsistent)
    }

    /// The calling thread's slot ID, allocating one on first use.
    ///
    /// This is on the hot read path, so the steady-state cost is a single
    /// `pthread_getspecific`.
    @inlinable
    static func currentID() -> Int {
        guard let stored = pthread_getspecific(slotKey) else {
            return allocateID()
        }
        let encoded = UInt(bitPattern: stored)
        if encoded == exhaustedMarker {
            return invalidID
        }
        return Int(encoded) - idBias
    }

    /// The calling thread's slot ID if it already has one, and ``invalidID``
    /// otherwise.
    ///
    /// ``currentID()`` with the allocation removed, which is the whole point: a
    /// writer asking whether it is itself one of the readers it is waiting on
    /// must not become one by asking. A thread that only ever writes would
    /// otherwise consume a slot it will never read from.
    static func assignedID() -> Int {
        guard let stored = pthread_getspecific(slotKey) else {
            return invalidID
        }
        let encoded = UInt(bitPattern: stored)
        if encoded == exhaustedMarker {
            return invalidID
        }
        return Int(encoded) - idBias
    }

    @usableFromInline
    static func allocateID() -> Int {
        allocationLock.lock()
        let id = availableIDs.popLast()
        if let id {
            // Published here, which is necessarily before this thread can enter
            // a read section — that is what makes it safe for a writer's drain
            // to skip the slots it does not see in the mask.
            _ = allocatedSlots.bitwiseOrThenLoad(with: 1 << UInt64(id), ordering: .sequentiallyConsistent)
        }
        allocationLock.unlock()

        guard let id else {
            // Remember the failure so the next read skips the lock entirely.
            // A thread that overflows stays on the slow path for its lifetime,
            // even if another thread later exits and frees its slot.
            pthread_setspecific(slotKey, UnsafeMutableRawPointer(bitPattern: exhaustedMarker))
            // Once per thread, ever — the counter costs nothing, and it is the
            // only way an application can find out that its thread population
            // has outgrown `capacity`.
            ZinjectDiagnostics.countThreadWithoutSlot()
            return invalidID
        }

        pthread_setspecific(slotKey, UnsafeMutableRawPointer(bitPattern: UInt(id + idBias)))
        return id
    }

    fileprivate static func recycleID(encoded: UInt) {
        guard encoded != exhaustedMarker else { return }
        let id = Int(encoded) - idBias
        guard id >= 0, id < capacity else { return }
        allocationLock.lock()
        availableIDs.append(id)
        // Cleared from the thread's own pthread destructor, so the thread has
        // already stopped running and cannot still be inside a read section.
        // A drain that no longer sees this bit is therefore not overlooking a
        // reader; it is skipping a slot that is provably zero.
        _ = allocatedSlots.bitwiseAndThenLoad(with: ~(1 << UInt64(id)), ordering: .sequentiallyConsistent)
        allocationLock.unlock()
    }
}

/// The thread-local slot holding this thread's biased reader ID.
///
/// Initialized exactly once via Swift's lazy global initialization, which is
/// itself `swift_once`-backed and therefore thread-safe.
@usableFromInline
let slotKey: pthread_key_t = {
    var key = pthread_key_t()
    let status = pthread_key_create(&key) { value in
        // Runs on thread exit. The pointer is the biased ID, not an allocation,
        // so there is nothing to free — just return the slot to the pool.
        ReaderRegistry.recycleID(encoded: UInt(bitPattern: value))
    }
    precondition(status == 0, "Zinject: pthread_key_create failed with status \(status)")
    return key
}()
