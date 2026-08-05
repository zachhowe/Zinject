struct ServiceKey: Hashable, Sendable {
    let id: ObjectIdentifier
    let resolvingType: Any.Type

    init(resolvingType: Any.Type) {
        self.id = ObjectIdentifier(resolvingType)
        self.resolvingType = resolvingType
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ServiceKey, rhs: ServiceKey) -> Bool {
        lhs.id == rhs.id
    }
}
