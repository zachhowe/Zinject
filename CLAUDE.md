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

- **Container**: Main DI container implementing `Resolver` protocol. Thread-safe via a single `NSRecursiveLock` guarding both the factory and instance dictionaries
- **Resolver**: Protocol defining service resolution interface; also provides `resolveRequired(_:)` (traps on missing registration)
- **ServiceFactory**: Internal factory pattern for service creation with scope management; `create` and `runInitCompleted` are separate so the container can cache instances before callbacks run
- **Scope**: Enum defining service lifetimes (`.transient`, `.container`)
- **ServiceKey**: Type-based key system for service registration/resolution (`ObjectIdentifier`-based equality)

### Key Patterns

- Services are registered with factory closures: `container.register(Type.self) { resolver in ... }`
- Distinct `register` (`@Sendable` factory) and `registerMainActor` (`@MainActor` factory) methods; main-actor factories run inline on the main thread or hop via `DispatchQueue.main.sync` otherwise
- Fluent API for configuration: `.scope(.container)`, `.initCompleted { ... }` (multiple callbacks accumulate)
- Recursive dependency resolution through resolver parameter in factories; circular dependencies are detected via a per-thread resolution stack and trap with a descriptive message
- Re-registering a type evicts its cached instance; `unregister(_:)` and `removeAll()` provide teardown
- The container lock is never held while user code (factories, `initCompleted`) runs — under a concurrent first resolve, a factory may run more than once but only one instance is ever cached/returned

### Test Structure

Tests use Swift Testing framework (`import Testing`) with `@Test` attribute. Test classes A, B, C demonstrate dependency chains and scoping behavior.