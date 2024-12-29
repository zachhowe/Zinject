struct ServiceKey: Hashable, Equatable, Sendable {
    let resolvingType: Any.Type

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(resolvingType))
    }

    static func == (lhs: ServiceKey, rhs: ServiceKey) -> Bool {
        lhs.hashValue == rhs.hashValue
    }
}
