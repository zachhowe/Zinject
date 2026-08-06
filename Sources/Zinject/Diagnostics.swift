import Atomics

/// Process-wide counters describing how well ``ConcurrencyStrategy/leftRight``
/// is actually working in this process.
///
/// Reading these is the cheapest way to find out whether Left-Right is helping
/// or hurting a real application, because the failure mode it has is silent.
/// `ReaderRegistry` hands out a fixed number of wait-free reader slots
/// (`ReaderRegistry.capacity`, currently 64), recycled only when a thread exits.
/// A process with more live resolving threads than that gives the overflow
/// threads no slot, and their reads fall back to taking the writer lock — the
/// same serialization a mutex would impose, on top of Left-Right's much more
/// expensive writes. Nothing about that is visible from the outside.
///
/// So: a non-zero ``slotlessReads`` means Left-Right is running *worse* than
/// ``ConcurrencyStrategy/unfairLock`` would in this process, and the strategy
/// should be switched. Zero means the wait-free path is being taken as designed.
///
/// Both counters are incremented only on paths that were already slow —
/// ``threadsWithoutSlot`` at most once per thread for the lifetime of the
/// process, ``slotlessReads`` from inside a call that goes on to take a lock. A
/// reader holding a slot never touches either, so the fast path is unchanged.
public enum ZinjectDiagnostics {
    /// How many threads can hold a wait-free reader slot at once.
    ///
    /// Exposed so an application can compare it against its own thread
    /// population — and so the benchmark can size a run that deliberately
    /// exceeds it.
    public static var readerSlotCapacity: Int { ReaderRegistry.capacity }

    /// Threads that asked for a reader slot and found none left.
    ///
    /// Counted once per thread. A thread that overflows stays on the slow path
    /// for its whole lifetime even if slots free up later, so this is a count of
    /// permanently degraded threads, not of transient misses.
    public static var threadsWithoutSlot: Int {
        threadsWithoutSlotCounter.load(ordering: .relaxed)
    }

    /// Reads that took the writer-lock fallback because the calling thread had
    /// no reader slot.
    ///
    /// The number that matters. If this is climbing in an application, that
    /// application is paying for Left-Right and not receiving it.
    public static var slotlessReads: Int {
        slotlessReadsCounter.load(ordering: .relaxed)
    }

    /// Zeroes both counters, so a measurement can cover one phase of a run
    /// rather than everything since launch.
    public static func reset() {
        threadsWithoutSlotCounter.store(0, ordering: .relaxed)
        slotlessReadsCounter.store(0, ordering: .relaxed)
    }

    static func countThreadWithoutSlot() {
        threadsWithoutSlotCounter.wrappingIncrement(ordering: .relaxed)
    }

    static func countSlotlessRead() {
        slotlessReadsCounter.wrappingIncrement(ordering: .relaxed)
    }
}

// Relaxed throughout: these are diagnostics, and no other memory's visibility
// depends on them. Ordering them would cost the slow path for nothing.
private let threadsWithoutSlotCounter = ManagedAtomic<Int>(0)
private let slotlessReadsCounter = ManagedAtomic<Int>(0)
