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

- **Container**: Main DI container implementing `Resolver` protocol. Thread-safe with `@Atomic` property wrappers
- **Resolver**: Protocol defining service resolution interface
- **ServiceFactory**: Internal factory pattern for service creation with scope management
- **Scope**: Enum defining service lifetimes (`.transient`, `.container`)
- **ServiceKey**: Type-based key system for service registration/resolution

### Key Patterns

- Services are registered with factory closures: `container.register(Type.self) { resolver in ... }`
- Both `@Sendable` and `@MainActor` factory overloads supported
- Fluent API for configuration: `.scope(.container)`, `.initCompleted { ... }`
- Recursive dependency resolution through resolver parameter in factories
- Thread-safety achieved via `@Atomic` wrapper and `@unchecked Sendable` conformance

### Test Structure

Tests use Swift Testing framework (`import Testing`) with `@Test` attribute. Test classes A, B, C demonstrate dependency chains and scoping behavior.