public protocol Resolver: Sendable {
    func resolve<Service>(_ type: Service.Type) -> Service?
}

// ``Container/withResolvedRequired(_:_:)`` is deliberately *not* a requirement
// here, and should not be added as one. The only default implementation this
// protocol could offer is `try body(resolveRequired(type))`, which retains — and
// an API whose entire value is that it touches no reference count must not have
// a conforming path where that claim is quietly false. Nor could the existential
// benefit: lending at +0 depends on the call specializing, and a witness-table
// dispatch already costs more than the retain it would save.

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
