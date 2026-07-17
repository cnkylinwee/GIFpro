import Carbon
import Foundation

struct GlobalHotKeyIdentifier: Equatable {
    let signature: UInt32
    let id: UInt32
}

protocol GlobalHotKeyRegistering: AnyObject {
    func register(
        identifier: GlobalHotKeyIdentifier,
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping (GlobalHotKeyIdentifier) -> Void
    ) throws
    func unregister()
}

enum GlobalHotKeyError: Error, Equatable {
    case eventHandlerInstallationFailed(OSStatus)
    case registrationFailed(OSStatus)
}

final class GlobalHotKeyController {
    static let identifier = GlobalHotKeyIdentifier(signature: 0x4749_4650, id: 1) // GIFP

    private let registry: any GlobalHotKeyRegistering
    private let deliverOnMain: (@escaping () -> Void) -> Void
    private let action: () -> Void
    private var isStarted = false

    init(
        registry: any GlobalHotKeyRegistering = CarbonHotKeyRegistry(),
        deliverOnMain: @escaping (@escaping () -> Void) -> Void = {
            DispatchQueue.main.async(execute: $0)
        },
        action: @escaping () -> Void
    ) {
        self.registry = registry
        self.deliverOnMain = deliverOnMain
        self.action = action
    }

    func start() throws {
        guard !isStarted else { return }

        try registry.register(
            identifier: Self.identifier,
            keyCode: UInt32(kVK_ANSI_G),
            modifiers: UInt32(optionKey | cmdKey)
        ) { [weak self] identifier in
            self?.receive(identifier)
        }
        isStarted = true
    }

    func stop() {
        guard isStarted else { return }
        registry.unregister()
        isStarted = false
    }

    deinit {
        stop()
    }

    private func receive(_ identifier: GlobalHotKeyIdentifier) {
        guard identifier == Self.identifier else { return }
        deliverOnMain(action)
    }
}

final class CarbonHotKeyRegistry: GlobalHotKeyRegistering {
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var callback: ((GlobalHotKeyIdentifier) -> Void)?

    func register(
        identifier: GlobalHotKeyIdentifier,
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping (GlobalHotKeyIdentifier) -> Void
    ) throws {
        guard eventHandler == nil, hotKey == nil else { return }
        callback = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyHandler,
            1,
            &eventType,
            context,
            &eventHandler
        )
        guard handlerStatus == noErr else {
            callback = nil
            eventHandler = nil
            throw GlobalHotKeyError.eventHandlerInstallationFailed(handlerStatus)
        }

        let carbonIdentifier = EventHotKeyID(
            signature: OSType(identifier.signature),
            id: identifier.id
        )
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            carbonIdentifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registrationStatus == noErr else {
            if let eventHandler {
                RemoveEventHandler(eventHandler)
            }
            eventHandler = nil
            hotKey = nil
            callback = nil
            throw GlobalHotKeyError.registrationFailed(registrationStatus)
        }
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        callback = nil
    }

    deinit {
        unregister()
    }

    fileprivate func handle(event: EventRef) -> OSStatus {
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
        callback?(
            GlobalHotKeyIdentifier(
                signature: UInt32(identifier.signature),
                id: identifier.id
            )
        )
        return noErr
    }
}

private let carbonHotKeyHandler: EventHandlerUPP = { _, event, context in
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    let registry = Unmanaged<CarbonHotKeyRegistry>.fromOpaque(context).takeUnretainedValue()
    return registry.handle(event: event)
}
