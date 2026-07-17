import Carbon
import Foundation
import OSLog

struct GlobalHotKeyIdentifier: Equatable, Sendable {
    let signature: UInt32
    let id: UInt32
}

@MainActor
protocol GlobalHotKeyRegistering: AnyObject, Sendable {
    func register(
        identifier: GlobalHotKeyIdentifier,
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping @MainActor (GlobalHotKeyIdentifier) -> Void
    ) throws
    func unregister() throws
}

enum GlobalHotKeyError: Error, Equatable {
    case eventHandlerInstallationFailed(OSStatus)
    case registrationFailed(OSStatus)
    case registrationRollbackFailed(registrationStatus: OSStatus, removalStatus: OSStatus)
    case unregistrationFailed(OSStatus)
    case eventHandlerRemovalFailed(OSStatus)
}

@MainActor
protocol CarbonHotKeyOperating: AnyObject {
    func installEventHandler(
        _ handler: EventHandlerUPP?,
        context: UnsafeMutableRawPointer
    ) -> (OSStatus, EventHandlerRef?)
    func registerHotKey(
        keyCode: UInt32,
        modifiers: UInt32,
        identifier: EventHotKeyID
    ) -> (OSStatus, EventHotKeyRef?)
    func unregisterHotKey(_ hotKey: EventHotKeyRef) -> OSStatus
    func removeEventHandler(_ handler: EventHandlerRef) -> OSStatus
}

@MainActor
final class GlobalHotKeyController {
    nonisolated static let identifier = GlobalHotKeyIdentifier(signature: 0x4749_4650, id: 1) // GIFP

    private let registry: any GlobalHotKeyRegistering
    private let deliverOnMain: (@escaping @MainActor @Sendable () -> Void) -> Void
    private let action: @MainActor () -> Void
    private var isStarted = false
    private var generation: UInt64 = 0

    init(
        registry: (any GlobalHotKeyRegistering)? = nil,
        deliverOnMain: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void = { action in
            Task { @MainActor in action() }
        },
        action: @escaping @MainActor () -> Void
    ) {
        self.registry = registry ?? CarbonHotKeyRegistry()
        self.deliverOnMain = deliverOnMain
        self.action = action
    }

    func start() throws {
        guard !isStarted else { return }
        let registrationGeneration = generation &+ 1

        try registry.register(
            identifier: Self.identifier,
            keyCode: UInt32(kVK_ANSI_G),
            modifiers: UInt32(optionKey | cmdKey)
        ) { [weak self] identifier in
            self?.receive(identifier, generation: registrationGeneration)
        }
        generation = registrationGeneration
        isStarted = true
    }

    func stop() throws {
        guard isStarted else { return }
        try registry.unregister()
        isStarted = false
    }

    deinit {
        guard isStarted else { return }
        let registry = registry
        Task { @MainActor in
            do {
                try registry.unregister()
            } catch {
                Logger.hotKey.error("Hot key teardown failed during controller deinit: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func receive(_ identifier: GlobalHotKeyIdentifier, generation: UInt64) {
        guard isStarted, identifier == Self.identifier, generation == self.generation else { return }
        deliverOnMain { [weak self] in
            guard let self, self.isStarted, self.generation == generation else { return }
            self.action()
        }
    }
}

@MainActor
final class CarbonHotKeyRegistry: GlobalHotKeyRegistering {
    private let operations: any CarbonHotKeyOperating
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var registeredIdentifier: GlobalHotKeyIdentifier?
    private var callback: (@MainActor (GlobalHotKeyIdentifier) -> Void)?
    private var retainedContext: UnsafeMutableRawPointer?

    init(operations: (any CarbonHotKeyOperating)? = nil) {
        self.operations = operations ?? SystemCarbonHotKeyOperations()
    }

    func register(
        identifier: GlobalHotKeyIdentifier,
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping @MainActor (GlobalHotKeyIdentifier) -> Void
    ) throws {
        guard eventHandler == nil, hotKey == nil else { return }
        callback = handler

        let callbackContext = CarbonHotKeyCallbackContext()
        let context = Unmanaged.passRetained(callbackContext).toOpaque()
        retainedContext = context
        let (handlerStatus, installedHandler) = operations.installEventHandler(
            carbonHotKeyHandler,
            context: context
        )
        eventHandler = installedHandler
        guard handlerStatus == noErr else {
            callback = nil
            eventHandler = nil
            releaseContext()
            throw GlobalHotKeyError.eventHandlerInstallationFailed(handlerStatus)
        }

        let carbonIdentifier = EventHotKeyID(
            signature: OSType(identifier.signature),
            id: identifier.id
        )
        let (registrationStatus, registeredHotKey) = operations.registerHotKey(
            keyCode: keyCode,
            modifiers: modifiers,
            identifier: carbonIdentifier
        )
        hotKey = registeredHotKey
        guard registrationStatus == noErr else {
            var removalStatus = noErr
            if let eventHandler {
                removalStatus = operations.removeEventHandler(eventHandler)
            }
            eventHandler = nil
            hotKey = nil
            callback = nil
            releaseContext()
            if removalStatus != noErr {
                throw GlobalHotKeyError.registrationRollbackFailed(
                    registrationStatus: registrationStatus,
                    removalStatus: removalStatus
                )
            }
            throw GlobalHotKeyError.registrationFailed(registrationStatus)
        }
        registeredIdentifier = identifier
        callbackContext.configure(identifier: identifier) { [weak self] identifier in
            _ = self?.handle(identifier: identifier)
        }
    }

    func unregister() throws {
        if let hotKey {
            let status = operations.unregisterHotKey(hotKey)
            guard status == noErr else {
                throw GlobalHotKeyError.unregistrationFailed(status)
            }
            self.hotKey = nil
            registeredIdentifier = nil
            callbackContext()?.clear()
        }
        if let eventHandler {
            let status = operations.removeEventHandler(eventHandler)
            self.eventHandler = nil
            releaseContext()
            callback = nil
            if status != noErr {
                throw GlobalHotKeyError.eventHandlerRemovalFailed(status)
            }
        }
        registeredIdentifier = nil
        callback = nil
    }

    func handle(identifier: GlobalHotKeyIdentifier) -> OSStatus {
        guard identifier == registeredIdentifier else {
            return OSStatus(eventNotHandledErr)
        }
        callback?(identifier)
        return noErr
    }

    private func releaseContext() {
        guard let retainedContext else { return }
        Unmanaged<CarbonHotKeyCallbackContext>.fromOpaque(retainedContext).release()
        self.retainedContext = nil
    }

    private func callbackContext() -> CarbonHotKeyCallbackContext? {
        guard let retainedContext else { return nil }
        return Unmanaged<CarbonHotKeyCallbackContext>
            .fromOpaque(retainedContext)
            .takeUnretainedValue()
    }
}

@MainActor
final class SystemCarbonHotKeyOperations: CarbonHotKeyOperating {
    func installEventHandler(
        _ handler: EventHandlerUPP?,
        context: UnsafeMutableRawPointer
    ) -> (OSStatus, EventHandlerRef?) {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var eventHandler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &eventType, context, &eventHandler
        )
        return (status, eventHandler)
    }

    func registerHotKey(
        keyCode: UInt32,
        modifiers: UInt32,
        identifier: EventHotKeyID
    ) -> (OSStatus, EventHotKeyRef?) {
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey
        )
        return (status, hotKey)
    }

    func unregisterHotKey(_ hotKey: EventHotKeyRef) -> OSStatus {
        UnregisterEventHotKey(hotKey)
    }

    func removeEventHandler(_ handler: EventHandlerRef) -> OSStatus {
        RemoveEventHandler(handler)
    }
}

private let carbonHotKeyHandler: EventHandlerUPP = { _, event, context in
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr else { return status }
    let callbackContext = Unmanaged<CarbonHotKeyCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    return callbackContext.dispatch(
        GlobalHotKeyIdentifier(signature: UInt32(identifier.signature), id: identifier.id)
    )
}

final class CarbonHotKeyCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private var registeredIdentifier: GlobalHotKeyIdentifier?
    private var callback: (@MainActor @Sendable (GlobalHotKeyIdentifier) -> Void)?

    init() {}

    func configure(
        identifier: GlobalHotKeyIdentifier,
        callback: @escaping @MainActor @Sendable (GlobalHotKeyIdentifier) -> Void
    ) {
        lock.withLock {
            registeredIdentifier = identifier
            self.callback = callback
        }
    }

    func clear() {
        lock.withLock {
            registeredIdentifier = nil
            callback = nil
        }
    }

    func dispatch(_ identifier: GlobalHotKeyIdentifier) -> OSStatus {
        let callback: (@MainActor @Sendable (GlobalHotKeyIdentifier) -> Void)? = lock.withLock {
            registeredIdentifier == identifier ? self.callback : nil
        }
        guard let callback else { return OSStatus(eventNotHandledErr) }
        Task { @MainActor in
            callback(identifier)
        }
        return noErr
    }
}

private extension Logger {
    static let hotKey = Logger(subsystem: "com.gifpro.app", category: "GlobalHotKey")
}
