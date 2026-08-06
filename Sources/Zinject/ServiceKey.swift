@usableFromInline
struct ServiceKey: Hashable, Sendable {
    /// The service type's metadata pointer, which is what ``ServiceTable``
    /// hashes and probes on. Held as raw bits rather than as an
    /// `ObjectIdentifier` so the table can multiply it directly; the conversion
    /// is free, but doing it per lookup is not free to read.
    @usableFromInline
    let raw: UInt

    @usableFromInline
    let resolvingType: Any.Type

    @inlinable
    init(resolvingType: Any.Type) {
        self.raw = UInt(bitPattern: ObjectIdentifier(resolvingType))
        self.resolvingType = resolvingType
    }

    @usableFromInline
    func hash(into hasher: inout Hasher) {
        hasher.combine(raw)
    }

    @usableFromInline
    static func == (lhs: ServiceKey, rhs: ServiceKey) -> Bool {
        lhs.raw == rhs.raw
    }
}
