/// An open-addressed map from service type to its registration and cached
/// instance, replacing the two `[ServiceKey: …]` dictionaries the container
/// used to hold.
///
/// `Dictionary` was the most expensive single thing on the resolve fast path.
/// Hashing one `ServiceKey` through `Hasher` — SipHash-1-3 over a per-process
/// seed — and probing costs about 13 ns on Apple Silicon, against about 33 ns
/// for an entire cached resolve. None of that generality is needed here: a
/// service key *is* a type-metadata pointer. It is unique by construction,
/// never zero, and already spread well enough that one multiply is a sufficient
/// hash. Lookup drops to about 1 ns.
///
/// ## Layout
///
/// Parallel arrays, not one array of entries, and the two columns a cached
/// resolve touches — ``keys`` and ``instances`` — hold nothing reference
/// counted. Loading a combined entry would copy the factory reference and the
/// instance's owner along with the parts actually needed, and retaining one
/// shared object per resolve is exactly the cross-core traffic ``LeftRight``
/// exists to avoid. ``owners`` keeps that storage alive and is touched only by
/// writers; it is the reason ``instances`` may hold a bare pointer at all.
///
/// ## Value semantics
///
/// Plain Swift arrays, so `State` stays a value type: ``LeftRight`` keeps two
/// copies of it and mutates each in turn, and copy-on-write gives each copy its
/// own buffers the moment a writer touches one. Nothing here may be a reference
/// to shared storage.
@usableFromInline
struct ServiceTable {
    /// Empty slots hold zero, which no type-metadata pointer ever is.
    @usableFromInline
    static let emptyKey: UInt = 0

    /// 2⁶⁴ / φ. Multiplying by it moves the entropy of an aligned pointer —
    /// which lives in the middle bits, never the bottom three — up into the top
    /// bits, where the fold below can reach it.
    @usableFromInline
    static let goldenRatio: UInt = 0x9E37_79B9_7F4A_7C15

    /// Power-of-two sized, so probing wraps with a mask. Empty until the first
    /// registration: a container that is never used pays nothing for its table.
    @usableFromInline
    var keys: [UInt] = []

    /// Pointers to cached `.container`-scoped instances, indexed in step with
    /// ``keys``. Plain machine words, so a resolve that reads one performs no
    /// reference counting at all; ``owners`` is what keeps them valid.
    @usableFromInline
    var instances: [UnsafeMutableRawPointer?] = []

    /// The objects owning the storage ``instances`` points into, indexed in
    /// step with ``keys``. Never read on the resolve path — dropping an entry
    /// here is what frees the storage, and ``CachedInstance`` documents why
    /// that always happens at a point where no reader can be looking.
    @usableFromInline
    var owners: [AnyObject?] = []

    /// Registrations, indexed in step with ``keys``.
    @usableFromInline
    var factories: [(any ServiceFactory)?] = []

    /// Occupied slots. Growth keeps the load factor at or below ¾, which holds
    /// the average probe length near one for a table this small.
    @usableFromInline
    var count = 0

    @inlinable
    init() {}

    // MARK: - Reading

    /// The slot holding `key`, or `nil` if the table has no entry for it.
    ///
    /// Linear probing from the hashed position, stopping at the first empty
    /// slot — which terminates because the table is never allowed to fill.
    @inlinable
    @inline(__always)
    func slot(for key: ServiceKey) -> Int? {
        let capacity = keys.count
        guard capacity > 0 else { return nil }

        let mask = capacity &- 1
        var index = Self.startIndex(for: key.raw, mask: mask)
        while true {
            let occupant = keys[index]
            if occupant == key.raw { return index }
            if occupant == Self.emptyKey { return nil }
            index = (index &+ 1) & mask
        }
    }

    /// The storage holding the instance cached in `slot`, if any.
    ///
    /// Valid only for the duration of the read section that produced it. The
    /// caller must load the value out and keep the value, never the pointer.
    @inlinable
    @inline(__always)
    func instance(at slot: Int) -> UnsafeMutableRawPointer? {
        instances[slot]
    }

    @inlinable
    @inline(__always)
    func factory(at slot: Int) -> (any ServiceFactory)? {
        factories[slot]
    }

    @inlinable
    @inline(__always)
    static func startIndex(for raw: UInt, mask: Int) -> Int {
        let hash = raw &* goldenRatio
        return Int((hash ^ (hash >> 32)) & UInt(mask))
    }

    // MARK: - Writing

    /// Installs a registration, evicting any instance cached under the old one
    /// so that re-registering a type takes effect.
    mutating func setFactory(_ factory: any ServiceFactory, for key: ServiceKey) {
        let slot = reserveSlot(for: key)
        factories[slot] = factory
        instances[slot] = nil
        owners[slot] = nil
    }

    /// Caches an instance in a slot a caller has already located.
    mutating func setInstance<Service>(_ instance: CachedInstance<Service>, at slot: Int) {
        instances[slot] = UnsafeMutableRawPointer(instance.storage)
        owners[slot] = instance
    }

    /// Removes a type's registration and cached instance.
    ///
    /// Rebuilds rather than back-shifting the probe cluster. Deletion from an
    /// open-addressed table is the one operation that is easy to get subtly
    /// wrong, and `unregister` is rare enough — a teardown operation, never a
    /// resolve — that the simplest correct implementation is the right one.
    mutating func remove(_ key: ServiceKey) {
        guard let removed = slot(for: key) else { return }

        var rebuilt = ServiceTable()
        rebuilt.reserve(capacity: keys.count)
        for slot in keys.indices where keys[slot] != Self.emptyKey && slot != removed {
            let destination = rebuilt.reserveSlot(for: keys[slot])
            rebuilt.factories[destination] = factories[slot]
            rebuilt.instances[destination] = instances[slot]
            rebuilt.owners[destination] = owners[slot]
        }
        self = rebuilt
    }

    mutating func removeAll() {
        self = ServiceTable()
    }

    /// The slot `key` belongs in, growing the table first if this would be a new
    /// entry and the table is at its load limit.
    private mutating func reserveSlot(for key: ServiceKey) -> Int {
        reserveSlot(for: key.raw)
    }

    private mutating func reserveSlot(for raw: UInt) -> Int {
        if (count &+ 1) &* 4 > keys.count &* 3 {
            grow()
        }

        let mask = keys.count &- 1
        var index = Self.startIndex(for: raw, mask: mask)
        while true {
            let occupant = keys[index]
            if occupant == raw { return index }
            if occupant == Self.emptyKey {
                keys[index] = raw
                count &+= 1
                return index
            }
            index = (index &+ 1) & mask
        }
    }

    private mutating func grow() {
        var rebuilt = ServiceTable()
        rebuilt.reserve(capacity: keys.isEmpty ? 8 : keys.count * 2)
        for slot in keys.indices where keys[slot] != Self.emptyKey {
            let destination = rebuilt.reserveSlot(for: keys[slot])
            rebuilt.factories[destination] = factories[slot]
            rebuilt.instances[destination] = instances[slot]
            rebuilt.owners[destination] = owners[slot]
        }
        self = rebuilt
    }

    private mutating func reserve(capacity: Int) {
        let rounded = max(8, capacity)
        precondition(rounded & (rounded - 1) == 0, "Zinject: table capacity must be a power of two")
        keys = Array(repeating: Self.emptyKey, count: rounded)
        instances = Array(repeating: nil, count: rounded)
        owners = Array(repeating: nil, count: rounded)
        factories = Array(repeating: nil, count: rounded)
        count = 0
    }
}
