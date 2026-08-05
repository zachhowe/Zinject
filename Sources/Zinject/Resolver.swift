public protocol Resolver: Sendable {
    func resolve<Service>(_ type: Service.Type) -> Service?
}

extension Resolver {
    /// Resolves a service, trapping with a descriptive message if it is not
    /// registered. Use this instead of force-unwrapping `resolve(_:)`.
    public func resolveRequired<Service>(_ type: Service.Type) -> Service {
        guard let service = resolve(type) else {
            preconditionFailure("Zinject: failed to resolve required service \(type)")
        }
        return service
    }
}
