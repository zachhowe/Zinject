# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Zinject is a lightweight dependency injection container for Swift, built using Swift Package Manager. It provides thread-safe service registration and resolution with configurable scoping.

## Development Commands

### Building and Testing
- Build: `swift build`
- Test: `swift test`
- Test specific target: `swift test --filter ZinjectTests`

### Package Management
- Resolve dependencies: `swift package resolve`
- Generate Xcode project: `swift package generate-xcodeproj`

## Architecture

### Core Components

- **Container**: Main DI container implementing `Resolver` protocol. Thread-safe via a single `NSRecursiveLock` guarding the factory, instance, and in-flight-construction dictionaries
- **ConstructionToken** (private, `Container.swift`): one per `.container`-scoped key whose factory is running. The thread that installs it constructs; others wait on its `NSCondition`. A thread that finds its *own* token has re-entered its own construction — that is a cycle, not a race — so it must fall through rather than wait, letting `pushResolutionStack` trap with the rendered chain
- **Resolver**: Protocol defining service resolution interface; also provides `resolveRequired(_:)` (traps on missing registration)
- **ServiceFactory**: Internal factory pattern for service creation with scope management; `create` and `runInitCompleted` are separate so the container can cache instances before callbacks run. `AnyObject`-constrained, because `Container.construct` identity-compares the factory it ran against the live registration before caching. `requiresMainActor` lets `resolveAsync` hop only where needed
- **Scope**: Enum defining service lifetimes (`.transient`, `.container`)
- **ServiceKey**: Type-based key system for service registration/resolution (`ObjectIdentifier`-based equality)

### Key Patterns

- Services are registered with factory closures: `container.register(Type.self) { resolver in ... }`
- Distinct `register` (`@Sendable` factory) and `registerMainActor` (`@MainActor` factory) methods; a main-actor factory runs inline on the main thread and **traps** off it. `resolveAsync(_:)` is the supported off-main path — it `await`s a main-actor hop only when the registration needs one and nothing has constructed the service yet. It replaced a `DispatchQueue.main.sync` hop that deadlocked whenever main was waiting on the caller, and that only reproduced on a cache miss
- Fluent API for configuration: `.scope(.container)`, `.initCompleted { ... }` (multiple callbacks accumulate)
- Recursive dependency resolution through resolver parameter in factories; circular dependencies are detected via a per-thread resolution stack and trap with a descriptive message
- Re-registering a type evicts its cached instance; `unregister(_:)` and `removeAll()` provide teardown
- The container lock is never held while user code (factories, `initCompleted`) runs. A `.container`-scoped service is nonetheless constructed **exactly once** under a concurrent first resolve, because construction is serialized per key by a `ConstructionToken` rather than by the container lock — a slow factory for one type never blocks resolving another. `.transient` is deliberately not serialized
- An instance built by a registration that was replaced mid-construction is returned to its own caller but never cached, so it cannot outlive the registration it came from

### Test Structure

Tests use Swift Testing framework (`import Testing`) with `@Test` attribute. Test classes A, B, C demonstrate dependency chains and scoping behavior.