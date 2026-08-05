# Zinject

A lightweight, thread-safe dependency injection container for Swift.

## Installation

Add Zinject to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/zachhowe/Zinject.git", branch: "master"),
]
```

Requires Swift 6.0+. Supports macOS 10.15+, iOS 13+, tvOS 13+, and watchOS 6+.

## Usage

### Registering and resolving

```swift
import Zinject

let container = Container()

container.register(APIClient.self) { _ in APIClient() }
container.register(UserService.self) { resolver in
    UserService(client: resolver.resolve(APIClient.self)!)
}

let service = container.resolve(UserService.self)          // UserService?
let required = container.resolveRequired(UserService.self) // UserService, traps if unregistered
```

### Scopes

Services default to `.container` scope (one shared instance per container). Use `.transient` for a new instance on every resolve. The default is configurable per container, and overridable per registration:

```swift
let container = Container(defaultScope: .transient)

container.register(Logger.self) { _ in Logger() }
    .scope(.container) // override: shared instance
```

### Post-initialization callbacks

```swift
container.register(Coordinator.self) { _ in Coordinator() }
    .initCompleted { resolver, coordinator in
        coordinator.delegate = resolver.resolve(AppDelegateProxy.self)
    }
```

Multiple `initCompleted` callbacks may be attached; they run in registration order. For `.container`-scoped services, the instance is cached before the callbacks run, so a callback may resolve its own type without recursing.

### Main-actor factories

For services that must be constructed on the main actor (e.g. UI-related objects):

```swift
container.registerMainActor(ViewModelFactory.self) { resolver in
    ViewModelFactory() // runs on the main actor
}
```

Resolving from the main thread runs the factory inline; resolving from any other thread synchronously hops to the main queue.

### Teardown

```swift
container.register(Config.self) { _ in Config(env: "test") } // re-registering evicts the cached instance
container.unregister(Config.self)                            // remove one registration
container.removeAll()                                        // remove everything
```

## Thread safety

`Container` is safe to use from multiple threads. Two behaviors are worth knowing:

- The container's lock is never held while your code (factories, `initCompleted` callbacks) runs. If multiple threads race to resolve a `.container`-scoped service for the *first* time, the factory may run more than once — but only one instance is ever cached and returned; the extras are discarded and their `initCompleted` callbacks never run. Keep factories free of one-shot side effects.
- Circular dependencies (A → B → A) are detected during resolution and trap with a message describing the cycle.

## License

Public domain, via [the Unlicense](https://unlicense.org). See [LICENSE](LICENSE).
