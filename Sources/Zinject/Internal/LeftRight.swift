import Atomics
import Foundation

/// A ``StateCell`` for data that is read constantly and written rarely, after
/// Ramalhete & Correia's Left-Right technique.
///
/// Two copies of the value are kept. Readers are directed at one of them and
/// never block, never retry, and never write to memory another reader touches.
/// Writers take a mutex, apply their change to the copy nobody is reading,
/// redirect readers to it, wait for the stragglers to leave the old copy, and
/// then replay the same change there so the two converge again.
///
/// The cost is asymmetric on purpose: reads are wait-free and scale with core
/// count, while writes pay two applications of the change plus two drains.
///
/// ## Correctness requirements
///
/// These are the ``StateCell`` contract, restated with the reason each clause
/// exists here:
///
/// - **Read bodies must be short and non-blocking.** A writer cannot finish
///   until every reader that entered before its flip has left. A read body that
///   blocks, or that runs arbitrary user code, stalls all writers behind it.
/// - **Read bodies must not re-enter this instance's ``write(_:)``.** Doing so
///   deadlocks: the writer would wait for a drain that includes its own slot.
/// - **Write bodies must be pure functions of the state handed to them.** The
///   body runs *twice*, against two copies that are identical when the write
///   begins, so it must reach the same decision both times. Captured mutable
///   state, side effects, and any dependence on time or randomness are unsound
///   here. The value returned to the caller comes from the first application.
@usableFromInline
final class LeftRight<T>: StateCell, @unchecked Sendable {
    /// Apple Silicon's 128-byte lines are the widest we need to defend against;
    /// on 64-byte-line machines this merely over-pads.
    private static var cacheLineSize: Int { 128 }

    /// The two copies. Readers borrow one, writers mutate the other.
    @usableFromInline
    let instances: UnsafeMutablePointer<T>

    /// `2 * ReaderRegistry.capacity` counters, one per (indicator, thread),
    /// each padded out to its own cache line so that two readers arriving
    /// concurrently never invalidate each other's line.
    @usableFromInline
    let readIndicators: UnsafeMutablePointer<Int.AtomicRepresentation>

    /// Number of `Int.AtomicRepresentation` elements between adjacent counters.
    @usableFromInline
    let slotStride: Int

    /// Which copy in ``instances`` readers should currently use.
    @usableFromInline
    let activeInstance: UnsafeAtomic<Int>

    /// Which of the two read indicators readers should currently register in.
    /// Deliberately independent of ``activeInstance`` — collapsing the two into
    /// one variable breaks the algorithm.
    @usableFromInline
    let activeIndicator: UnsafeAtomic<Int>

    /// Serializes writers against each other, and guards the slow path taken by
    /// threads that could not get a reader slot.
    ///
    /// Recursive, and that is load-bearing rather than defensive. A reader
    /// holding a slot can nest a read — its counter simply goes to two — so a
    /// reader *without* one has to be able to as well, or nesting a read becomes
    /// a function of how many threads the process happened to have running. That
    /// is the worst shape a bug can have: identical code is safe at sixteen live
    /// reader threads and deadlocks at a hundred and twenty-eight, so it passes
    /// every test and every simulator run and then hangs on a loaded device.
    ///
    /// Nothing on the cached-resolve path touches this lock; only writers and
    /// slotless readers do.
    @usableFromInline
    let writerLock = NSRecursiveLock()

    /// Read sections this thread has open on the slotless path.
    ///
    /// Mutated only while ``writerLock`` is held, which is what makes the plain
    /// integer sufficient — and what makes a non-zero value observed inside
    /// ``write(_:)`` necessarily this thread's own, since any other thread's
    /// slotless read would still be holding the lock we just took.
    ///
    /// Behind a pointer rather than a stored `var` because a class's stored
    /// properties carry dynamic exclusivity enforcement, and this is touched
    /// twice per slotless read — a path that is already the degraded one and
    /// does not need help.
    private let slotlessReadDepth: UnsafeMutablePointer<Int>

    @usableFromInline
    init(_ initial: T) {
        let stride = Self.cacheLineSize / MemoryLayout<Int.AtomicRepresentation>.stride
        let slotCount = 2 * ReaderRegistry.capacity

        slotStride = stride

        instances = .allocate(capacity: 2)
        instances.initialize(repeating: initial, count: 2)

        // `calloc` rather than allocate-then-initialize: the indicator array is
        // 16 KiB, and writing all of it up front would dominate the cost of
        // creating a container. Zeroed bytes are already a valid representation
        // of the integer 0 for this trivial storage type, and calloc's pages
        // fault in only as slots are actually used.
        let byteCount = slotCount * stride * MemoryLayout<Int.AtomicRepresentation>.stride
        guard let zeroed = calloc(1, byteCount) else {
            preconditionFailure("Zinject: could not allocate \(byteCount) bytes of read-indicator storage")
        }
        readIndicators = zeroed.bindMemory(
            to: Int.AtomicRepresentation.self,
            capacity: slotCount * stride
        )

        activeInstance = .create(0)
        activeIndicator = .create(0)

        slotlessReadDepth = .allocate(capacity: 1)
        slotlessReadDepth.initialize(to: 0)
    }

    deinit {
        instances.deinitialize(count: 2)
        instances.deallocate()

        // Trivial storage, so there is nothing to deinitialize — and the
        // allocation came from `calloc`, so it goes back through `free`.
        free(UnsafeMutableRawPointer(readIndicators))

        activeInstance.destroy()
        activeIndicator.destroy()

        slotlessReadDepth.deinitialize(count: 1)
        slotlessReadDepth.deallocate()
    }

    /// Borrows the currently active copy for the duration of `body`.
    ///
    /// Wait-free and population-oblivious for any thread holding a reader slot:
    /// one thread-local lookup, one increment of a private counter, one load,
    /// and one decrement. No loops, no contention with other readers.
    @inlinable
    func read<R>(_ body: (UnsafePointer<T>) -> R) -> R {
        let readerID = ReaderRegistry.currentID()
        guard readerID != ReaderRegistry.invalidID else {
            return readWithoutSlot(body)
        }

        // Relaxed is enough to pick an indicator. Reading a stale value here is
        // already a case the algorithm has to handle — a reader can be
        // descheduled between this load and the arrival below — and the
        // writer's two drains cover a reader landing in either indicator. What
        // matters is only that we depart from the one we arrived in.
        let indicator = activeIndicator.load(ordering: .relaxed)
        let slot = counter(indicator: indicator, readerID: readerID)

        // These two, by contrast, must both be sequentially consistent. They
        // and the writer's flip and drain participate in one total order: if a
        // drain misses this arrival, that order guarantees the load below sees
        // the flip, so we are sent to the copy the writer is not about to
        // touch. Weakening either reintroduces exactly that race.
        slot.wrappingIncrement(ordering: .sequentiallyConsistent)
        // Departing only needs to publish that our reads are finished, which
        // release ordering already does; the writer's drain acquires it.
        defer { slot.wrappingDecrement(ordering: .releasing) }

        let instance = activeInstance.load(ordering: .sequentiallyConsistent)
        return body(UnsafePointer(instances + instance))
    }

    /// See ``StateCell/read(_:)-throwing``. Identical to ``read(_:)`` but for
    /// the `try`: the departure is already `defer`red, so a body that throws
    /// leaves the read indicator exactly as a body that returns does. If it did
    /// not, the next write would wait on this thread's counter forever.
    @inlinable
    func read<R>(_ body: (UnsafePointer<T>) throws -> R) rethrows -> R {
        let readerID = ReaderRegistry.currentID()
        guard readerID != ReaderRegistry.invalidID else {
            return try readWithoutSlot(body)
        }

        let indicator = activeIndicator.load(ordering: .relaxed)
        let slot = counter(indicator: indicator, readerID: readerID)

        slot.wrappingIncrement(ordering: .sequentiallyConsistent)
        defer { slot.wrappingDecrement(ordering: .releasing) }

        let instance = activeInstance.load(ordering: .sequentiallyConsistent)
        return try body(UnsafePointer(instances + instance))
    }

    /// Applies `body` to both copies and returns the first application's result.
    ///
    /// See the type-level note: `body` runs twice and must be a pure function of
    /// the state it is given.
    @usableFromInline
    @discardableResult
    func write<R>(_ body: (inout T) -> R) -> R {
        writerLock.lock()
        defer { writerLock.unlock() }

        // Making the lock recursive is what lets a slotless read nest another
        // read; it must not also let one nest a *write*. Such a write would
        // sail through every step below — the drain finds nothing, because a
        // slotless reader announces itself in no indicator — and then replay
        // `body` over `previouslyActive`, which is the copy the read section
        // enclosing it is holding a pointer to. Silent, and only on the
        // fallback path.
        //
        // A reader that *did* get a slot is caught in `waitUntilDrained`
        // instead, where its own counter is the one that will never clear.
        if slotlessReadDepth.pointee != 0 {
            StateCellContract.reentrantWrite()
        }

        // Only writers touch these, and writers are serialized by the lock, so
        // relaxed loads are sufficient here.
        let previouslyActive = activeInstance.load(ordering: .relaxed)
        let inactive = 1 - previouslyActive

        // Nobody is reading the inactive copy, so this is unsynchronized.
        let result = body(&instances[inactive])

        // Send new readers to the copy we just updated.
        activeInstance.store(inactive, ordering: .sequentiallyConsistent)

        // Wait out the readers that entered before the flip and may still be
        // on the old copy.
        toggleIndicatorAndWait()

        // Nobody can be reading the old copy now; replay the change so the two
        // copies agree again before the next write starts.
        _ = body(&instances[previouslyActive])

        return result
    }

    /// Retires the current read indicator and waits for every reader that could
    /// still be on the pre-flip copy to leave.
    ///
    /// Both drains are load-bearing. A reader can be descheduled between reading
    /// ``activeIndicator`` and incrementing its counter, so it may register in
    /// what is by then the *stale* indicator. Draining the indicator we are
    /// about to adopt catches those stragglers before we start reusing it;
    /// draining the outgoing one catches everybody else.
    private func toggleIndicatorAndWait() {
        let current = activeIndicator.load(ordering: .relaxed)
        let next = 1 - current

        waitUntilDrained(indicator: next)
        activeIndicator.store(next, ordering: .sequentiallyConsistent)
        waitUntilDrained(indicator: current)
    }

    /// Spins until every counter in `indicator` that a live reader could be
    /// holding reads zero.
    ///
    /// A single ordered pass suffices. Any reader that could still be on the
    /// pre-flip copy already had a non-zero counter before this scan began — a
    /// reader that arrives mid-scan necessarily loaded ``activeInstance`` after
    /// the flip and is therefore on the new copy.
    ///
    /// The scan covers the reader IDs currently allocated, not all
    /// ``ReaderRegistry/capacity`` of them. Each counter sits on its own cache
    /// line and this runs twice per write, so scanning the whole array made
    /// every write pay for 64 threads in a process that had four.
    ///
    /// Bounding it is sound in both directions, and by the same total order the
    /// rest of the algorithm rests on:
    ///
    /// - **A bit this mask misses cannot be a reader on the old copy.** The load
    ///   below is sequentially consistent and follows this writer's flip of
    ///   ``activeInstance``, and a thread publishes its bit — also sequentially
    ///   consistent — before it can ever arrive in an indicator. So if the mask
    ///   does not contain reader *k*, then in the total order the flip precedes
    ///   *k*'s publication, which precedes *k*'s arrival and its load of
    ///   ``activeInstance``. That load therefore sees the flip, and *k* is on
    ///   the copy this writer is not about to touch.
    /// - **A bit that has been cleared cannot hide a reader still inside a
    ///   section.** Bits are cleared from the owning thread's pthread
    ///   destructor, which runs after that thread has stopped executing.
    ///
    /// A *stale set* bit is merely wasted work: the scan reads a zero and moves
    /// on.
    ///
    /// ## Diagnosing a writer that will never finish
    ///
    /// One counter can never reach zero: the calling thread's own. A thread
    /// inside a read section is holding a grace period open, and a writer waits
    /// for every grace period to close, so a thread that does both waits for
    /// itself. Recursive locking cannot fix that — it is the algorithm's central
    /// invariant, not a lock's re-entrancy — and the symptom is the worst
    /// available: a spin, not a blocked thread, so it burns a core and never
    /// appears in a deadlock detector.
    ///
    /// So the scan checks. If the counter it is waiting on belongs to the
    /// calling thread, that is proof rather than heuristic — no other thread can
    /// touch that counter — and it is worth a trap in every build, because the
    /// alternative is a hang. It costs one thread-local read per drain, on a
    /// path that only runs at registration time, and nothing at all until a
    /// counter is already refusing to clear.
    private func waitUntilDrained(indicator: Int) {
        var remaining = ReaderRegistry.allocatedSlotMask()

        // Deliberately not `currentID()`: a thread that only writes must not be
        // handed a reader slot merely for having asked this question.
        let callerID = ReaderRegistry.assignedID()

        while remaining != 0 {
            let readerID = remaining.trailingZeroBitCount
            remaining &= remaining &- 1

            let slot = counter(indicator: indicator, readerID: readerID)
            var spins = 0
            // Sequentially consistent, not merely acquiring: this load is the
            // other half of the total order that the reader's arrival relies
            // on. It is on the writer's rare path, so the strength is free.
            while slot.load(ordering: .sequentiallyConsistent) != 0 {
                if readerID == callerID {
                    StateCellContract.reentrantWrite()
                }
                spins += 1
                if spins >= 128 {
                    // Read sections are short, so spinning is normally right;
                    // yield anyway in case we are sharing a core with the
                    // reader we are waiting on.
                    sched_yield()
                    spins = 0
                }
            }
        }
    }

    /// Fallback for threads that arrived after every reader slot was taken.
    /// Correct but not wait-free: it excludes writers with the writer lock
    /// instead of announcing itself in a read indicator.
    ///
    /// A read that lands here is strictly worse off than it would be under
    /// ``ConcurrencyStrategy/unfairLock`` — same serialization, plus the
    /// double-application cost on every write. That makes it the signal worth
    /// counting, so ``ZinjectDiagnostics`` tallies it. The counter is free to
    /// the fast path: it is only touched by threads that are already about to
    /// take a lock.
    @usableFromInline
    func readWithoutSlot<R>(_ body: (UnsafePointer<T>) -> R) -> R {
        ZinjectDiagnostics.countSlotlessRead()
        writerLock.lock()
        slotlessReadDepth.pointee += 1
        defer {
            slotlessReadDepth.pointee -= 1
            writerLock.unlock()
        }
        let instance = activeInstance.load(ordering: .relaxed)
        return body(UnsafePointer(instances + instance))
    }

    @usableFromInline
    func readWithoutSlot<R>(_ body: (UnsafePointer<T>) throws -> R) rethrows -> R {
        ZinjectDiagnostics.countSlotlessRead()
        writerLock.lock()
        slotlessReadDepth.pointee += 1
        defer {
            slotlessReadDepth.pointee -= 1
            writerLock.unlock()
        }
        let instance = activeInstance.load(ordering: .relaxed)
        return try body(UnsafePointer(instances + instance))
    }

    @inlinable
    func counter(indicator: Int, readerID: Int) -> UnsafeAtomic<Int> {
        let slot = indicator * ReaderRegistry.capacity + readerID
        return UnsafeAtomic(at: readIndicators + slot * slotStride)
    }
}
