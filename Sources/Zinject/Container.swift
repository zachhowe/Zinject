public final class Container: @unchecked Sendable, Resolver {
    @Atomic private var serviceFactories: [ServiceKey: any ServiceFactory] = [:]
    @Atomic private var services: [ServiceKey: Any] = [:]

    public init() {}

    @discardableResult
    public func register<Service>(
        _ type: Service.Type,
        factory: @Sendable @escaping (Resolver) -> Service
    ) -> any ServiceEntry<Service> {
        let serviceFactory = ServiceFactoryImpl<Service>(factory: factory)
        let serviceKey = ServiceKey(resolvingType: type)
        serviceFactories[serviceKey] = serviceFactory
        return serviceFactory
    }

    public func resolve<Service>(_ type: Service.Type) -> Service? {
        let serviceKey = ServiceKey(resolvingType: type)

        if let service = services[serviceKey] {
            return service as? Service
        } else if let serviceFactory = serviceFactories[serviceKey] {
            if let service = serviceFactory.create(resolver: self) as? Service {
                services[serviceKey] = service
                return service
            }
            return nil
        }

        return nil
    }
}
