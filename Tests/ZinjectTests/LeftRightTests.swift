import Foundation
import Testing

@testable import Zinject

// MARK: - Fixtures

/// Two fields a writer always updates together. Any reader that observes
/// `doubled != value * 2` has been shown a copy that a writer was midway
/// through mutating.
private struct Paired {
    var value = 0
    var doubled = 0

    var isConsistent: Bool { doubled == value * 2 }

    mutating func advance() {
        value += 1
        doubled = value * 2
    }
}

// MARK: - Basics

@Test func readSeesInitialValue() {
    let leftRight = LeftRight(42)
    #expect(leftRight.read { $0.pointee } == 42)
}

@Test func writeIsVisibleToReaders() {
    let leftRight = LeftRight(0)
    leftRight.write { $0 = 7 }
    #expect(leftRight.read { $0.pointee } == 7)
}

@Test func writeReturnsResultOfFirstApplication() {
    let leftRight = LeftRight(0)
    let result = leftRight.write { state -> Int in
        state += 1
        return state
    }
    #expect(result == 1)
    #expect(leftRight.read { $0.pointee } == 1)
}

/// The regression test for the whole point of the second application. If a
/// write only mutated the inactive copy, successive writes would land on
/// alternating copies and every other increment would be lost.
@Test func repeatedWritesAccumulateAcrossBothCopies() {
    let leftRight = LeftRight(0)
    for _ in 0 ..< 10 {
        leftRight.write { $0 += 1 }
    }
    #expect(leftRight.read { $0.pointee } == 10)
}

@Test func writesToDictionaryStateAccumulate() {
    let leftRight = LeftRight([String: Int]())
    for index in 0 ..< 50 {
        leftRight.write { $0["key\(index)"] = index }
    }

    let snapshot = leftRight.read { $0.pointee }
    #expect(snapshot.count == 50)
    #expect(snapshot["key0"] == 0)
    #expect(snapshot["key49"] == 49)
}

@Test func removalIsAppliedToBothCopies() {
    let leftRight = LeftRight([String: Int]())
    leftRight.write { $0["a"] = 1 }
    leftRight.write { $0["b"] = 2 }
    leftRight.write { $0.removeValue(forKey: "a") }
    // A second write forces another flip, exposing the other copy to readers.
    leftRight.write { $0["c"] = 3 }

    let snapshot = leftRight.read { $0.pointee }
    #expect(snapshot["a"] == nil)
    #expect(snapshot["b"] == 2)
    #expect(snapshot["c"] == 3)
}

// MARK: - Concurrency

@Test func readersNeverObserveAPartiallyAppliedWrite() {
    let leftRight = LeftRight(Paired())
    let inconsistencies = Counter()
    let readerCount = 8
    let readsPerReader = 20_000
    let writeCount = 2_000

    DispatchQueue.concurrentPerform(iterations: readerCount + 1) { iteration in
        // Fixed iteration counts on both sides: neither role waits on the
        // other, so this cannot hang if the thread pool decides to serialize.
        if iteration == 0 {
            for _ in 0 ..< writeCount {
                leftRight.write { $0.advance() }
            }
        } else {
            for _ in 0 ..< readsPerReader {
                let consistent = leftRight.read { $0.pointee.isConsistent }
                if !consistent {
                    _ = inconsistencies.incrementAndGet()
                }
            }
        }
    }

    #expect(inconsistencies.current == 0)
    #expect(leftRight.read { $0.pointee.value } == writeCount)
}

@Test func readsObserveMonotonicallyAdvancingState() {
    let leftRight = LeftRight(Paired())
    let regressions = Counter()

    DispatchQueue.concurrentPerform(iterations: 5) { iteration in
        if iteration == 0 {
            for _ in 0 ..< 1_000 {
                leftRight.write { $0.advance() }
            }
        } else {
            var lastSeen = 0
            for _ in 0 ..< 10_000 {
                let seen = leftRight.read { $0.pointee.value }
                if seen < lastSeen {
                    _ = regressions.incrementAndGet()
                }
                lastSeen = seen
            }
        }
    }

    #expect(regressions.current == 0)
}

/// Writers must make progress while readers hammer the structure — the drain
/// spins, so a bug here shows up as a hang rather than a wrong answer.
@Test func writerCompletesUnderSustainedReadLoad() {
    let leftRight = LeftRight(0)
    let stop = StopFlag()
    let writesCompleted = Counter()

    let readers = DispatchQueue(label: "readers", attributes: .concurrent)
    let group = DispatchGroup()
    for _ in 0 ..< 6 {
        readers.async(group: group) {
            while !stop.value {
                _ = leftRight.read { $0.pointee }
            }
        }
    }

    for _ in 0 ..< 500 {
        leftRight.write { $0 += 1 }
        _ = writesCompleted.incrementAndGet()
    }
    stop.set()
    group.wait()

    #expect(writesCompleted.current == 500)
    #expect(leftRight.read { $0.pointee } == 500)
}

/// More concurrent threads than `ReaderRegistry.capacity`, so some are denied a
/// slot and take the writer-lock fallback. They must still read correctly.
@Test func readersBeyondSlotCapacityFallBackCorrectly() {
    let leftRight = LeftRight(Paired())
    leftRight.write { $0.advance() }

    let threadCount = ReaderRegistry.capacity + 24
    let inconsistencies = Counter()
    let barrier = DispatchGroup()

    for _ in 0 ..< threadCount {
        barrier.enter()
        let thread = Thread {
            for _ in 0 ..< 500 {
                let consistent = leftRight.read { $0.pointee.isConsistent }
                if !consistent {
                    _ = inconsistencies.incrementAndGet()
                }
            }
            barrier.leave()
        }
        thread.start()
    }

    for _ in 0 ..< 200 {
        leftRight.write { $0.advance() }
    }

    #expect(barrier.wait(timeout: .now() + 60) == .success)
    #expect(inconsistencies.current == 0)
}

// MARK: - Nesting on the slotless path

/// A reader holding a slot can nest a read: its counter goes to two and back.
/// A reader that could not get one has to be able to do the same, or whether
/// nesting works becomes a function of the process's thread population — safe on
/// a quiet machine, a deadlock on a busy one, and identical code either way.
///
/// Driven through `readWithoutSlot` directly rather than by starving the
/// registry, which makes it deterministic and keeps it from perturbing the
/// process-global slot pool that the rest of the suite shares.
/// ``nestedReadUnderRealSlotExhaustion`` covers the shape the bug actually takes.
@Test func nestedSlotlessReadDoesNotDeadlock() {
    let leftRight = LeftRight(11)
    let finished = DispatchGroup()
    nonisolated(unsafe) var inner = 0

    finished.enter()
    // On its own thread, so a regression is a failed timeout rather than a
    // hung test process.
    let thread = Thread {
        leftRight.readWithoutSlot { outer in
            inner = leftRight.readWithoutSlot { $0.pointee } + outer.pointee
        }
        finished.leave()
    }
    thread.start()

    #expect(finished.wait(timeout: .now() + 10) == .success, "a nested slotless read deadlocked")
    #expect(inner == 22)
}

/// The same property reached the way an application reaches it: enough live
/// threads that the registry runs out of slots, and then a nested `read`.
///
/// In a spawned process, and it has to be. Forcing the fallback means occupying
/// every slot there is, and the registry is process-global and shared with every
/// test running alongside this one — starving it in-process makes unrelated
/// tests take the fallback and fail, which is how this test was first written
/// and what it did.
///
/// Everything is asserted from inside the body, because `processExitsWith` can
/// only see the exit status. The wait timeouts are what turn a regression into a
/// failed exit rather than a hung test run, and the `invalidID` check is what
/// keeps a run in which the probe won a slot from passing while proving nothing.
@Test(.enabled(if: !isRunningUnderThreadSanitizer)) func nestedReadUnderRealSlotExhaustionDoesNotDeadlock() async throws {
    await #expect(processExitsWith: .success) {
        /// `DispatchGroup.wait` is unavailable from an async context, and this
        /// body is one. An `NSCondition` deadline is the same thing without the
        /// restriction.
        final class Latch: @unchecked Sendable {
            private let condition = NSCondition()
            private var remaining: Int

            init(_ count: Int) { remaining = count }

            func signal() {
                condition.lock()
                remaining -= 1
                condition.broadcast()
                condition.unlock()
            }

            func waitOut(seconds: TimeInterval) -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                condition.lock()
                defer { condition.unlock() }
                while remaining > 0 {
                    guard condition.wait(until: deadline) else { return false }
                }
                return true
            }
        }

        let leftRight = LeftRight(3)
        let parked = Latch(ReaderRegistry.capacity)

        // Parked rather than joined: a slot comes back when its thread exits,
        // so they have to still be alive when the probe asks for one.
        for _ in 0 ..< ReaderRegistry.capacity {
            let holder = Thread {
                _ = ReaderRegistry.currentID()
                parked.signal()
                Thread.sleep(forTimeInterval: 120)
            }
            holder.start()
        }
        guard parked.waitOut(seconds: 60) else { exit(EXIT_FAILURE) }

        let probed = Latch(1)
        let probe = Thread {
            guard ReaderRegistry.currentID() == ReaderRegistry.invalidID else {
                // Got a slot, so this run would exercise the wrong path.
                exit(EXIT_FAILURE)
            }
            leftRight.read { outer in
                guard leftRight.read({ $0.pointee }) + outer.pointee == 6 else {
                    exit(EXIT_FAILURE)
                }
            }
            probed.signal()
        }
        probe.start()

        guard probed.waitOut(seconds: 30) else { exit(EXIT_FAILURE) }
    }
}

/// Recursion on the fallback path must not extend to writes. A write nested in
/// a slotless read would find nothing to drain — a slotless reader announces
/// itself in no indicator — and then replay its body over the copy the enclosing
/// read is still holding.
@Test(.enabled(if: !isRunningUnderThreadSanitizer)) func writeFromInsideSlotlessReadTraps() async throws {
    let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
        let leftRight = LeftRight(0)
        leftRight.readWithoutSlot { _ in
            leftRight.write { $0 += 1 }
        }
    }
    // The same diagnosis a slotted reader gets from the drain. Which path a
    // thread took is not something it chose, so it must not change what it is
    // told.
    let diagnosis = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
    #expect(diagnosis.contains("write was performed from inside this thread's own read section"))
}

// MARK: - Reader registry

@Test func readerIDsAreStablePerThreadAndDistinctAcrossThreads() {
    let threadCount = 8
    let recorded = ReaderIDLog()
    let allRecorded = DispatchGroup()
    let finished = DispatchGroup()
    // Threads park here after claiming an ID. Without this the earlier threads
    // would exit and have their IDs recycled before the later ones start, and
    // reusing a free slot is correct behaviour rather than a collision.
    let holdSlots = DispatchSemaphore(value: 0)

    for _ in 0 ..< threadCount {
        allRecorded.enter()
        finished.enter()
        let thread = Thread {
            let first = ReaderRegistry.currentID()
            let second = ReaderRegistry.currentID()
            recorded.record(first: first, second: second)
            allRecorded.leave()
            holdSlots.wait()
            finished.leave()
        }
        thread.start()
    }

    #expect(allRecorded.wait(timeout: .now() + 30) == .success)
    #expect(recorded.stableCount == threadCount, "a thread's ID must not change between calls")
    #expect(recorded.distinct.count == threadCount, "threads holding slots at once must not share one")
    #expect(!recorded.distinct.contains(ReaderRegistry.invalidID))

    for _ in 0 ..< threadCount { holdSlots.signal() }
    #expect(finished.wait(timeout: .now() + 30) == .success)
}

/// IDs are returned to the pool on thread exit, so a program that churns
/// through far more threads than `capacity` never exhausts it.
@Test func readerIDsAreRecycledWhenThreadsExit() {
    for _ in 0 ..< (ReaderRegistry.capacity * 3) {
        let group = DispatchGroup()
        group.enter()
        var observed = ReaderRegistry.invalidID
        let thread = Thread {
            observed = ReaderRegistry.currentID()
            group.leave()
        }
        thread.start()
        #expect(group.wait(timeout: .now() + 10) == .success)
        // Give the pthread destructor a moment to return the slot.
        Thread.sleep(forTimeInterval: 0.001)
        #expect(observed != ReaderRegistry.invalidID)
    }
}

/// A writer's drain scans the slots this mask reports, so the mask has to be
/// able to name every slot there is.
@Test func allocatedSlotMaskCoversEveryReaderID() {
    #expect(ReaderRegistry.capacity <= UInt64.bitWidth)
}

/// The mask is what bounds `waitUntilDrained`, and the reason it is the live set
/// rather than a high-water mark is that it has to come back down: a process
/// that once spiked to many threads must not keep paying for them on every
/// write. Both directions are checked here.
///
/// The clearing direction gets several rounds because the pool is process-wide
/// and these tests run in parallel: a slot freed here can be handed straight to
/// a thread another test is using, which sets the same bit again for reasons
/// that have nothing to do with this one. Observing it clear in *any* round is
/// the guarantee — a mark that never came down would never clear in any.
@Test func allocatedSlotMaskTracksLiveThreadsInBothDirections() {
    var everCleared = false

    for _ in 0 ..< 10 where !everCleared {
        let claimed = DispatchGroup()
        let release = DispatchSemaphore(value: 0)
        let exited = DispatchGroup()
        nonisolated(unsafe) var readerID = ReaderRegistry.invalidID

        claimed.enter()
        exited.enter()
        let thread = Thread {
            readerID = ReaderRegistry.currentID()
            claimed.leave()
            release.wait()
            exited.leave()
        }
        thread.start()

        #expect(claimed.wait(timeout: .now() + 30) == .success)
        #expect(readerID != ReaderRegistry.invalidID)
        let bit = UInt64(1) << UInt64(readerID)
        // Deterministic: that thread is parked and still holds its ID.
        #expect(ReaderRegistry.allocatedSlotMask() & bit != 0, "a live slot holder must be in the mask")

        release.signal()
        #expect(exited.wait(timeout: .now() + 30) == .success)

        // The bit clears in the thread's pthread destructor, which runs a
        // moment after the thread's body returns.
        for _ in 0 ..< 2000 where !everCleared {
            if ReaderRegistry.allocatedSlotMask() & bit == 0 {
                everCleared = true
            } else {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
    }

    #expect(everCleared, "an exited thread's slot must leave the mask, or writes keep paying for it")
}

// MARK: - Test helpers

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

private final class ReaderIDLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int] = []
    private var stable = 0

    func record(first: Int, second: Int) {
        lock.lock()
        ids.append(first)
        if first == second { stable += 1 }
        lock.unlock()
    }

    var distinct: Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return Set(ids)
    }

    var stableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stable
    }
}
