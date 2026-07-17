import Carbon
import Testing
@testable import GIFpro

@Suite("Global hot key")
struct GlobalHotKeyControllerTests {
    @Test("Start registers Command-Option-G exactly once")
    func startRegistersExpectedShortcutOnce() throws {
        let registry = FakeHotKeyRegistry()
        let controller = makeController(registry: registry)

        try controller.start()
        try controller.start()

        #expect(registry.registerCallCount == 1)
        #expect(registry.keyCode == UInt32(kVK_ANSI_G))
        #expect(registry.modifiers == UInt32(optionKey | cmdKey))
        #expect(registry.identifier == GlobalHotKeyController.identifier)
    }

    @Test("Stop unregisters exactly once")
    func stopUnregistersExactlyOnce() throws {
        let registry = FakeHotKeyRegistry()
        let controller = makeController(registry: registry)
        try controller.start()

        controller.stop()
        controller.stop()

        #expect(registry.unregisterCallCount == 1)
    }

    @Test("Deinit unregisters an active shortcut")
    func deinitUnregistersActiveShortcut() throws {
        let registry = FakeHotKeyRegistry()
        var controller: GlobalHotKeyController? = makeController(registry: registry)
        try controller?.start()

        controller = nil

        #expect(registry.unregisterCallCount == 1)
    }

    @Test("Callback responds only to the registered hot key identifier")
    func callbackFiltersIdentifiers() throws {
        let registry = FakeHotKeyRegistry()
        var actionCallCount = 0
        let controller = makeController(registry: registry) {
            actionCallCount += 1
        }
        try controller.start()

        registry.emit(GlobalHotKeyIdentifier(signature: 0, id: 0))
        registry.emit(GlobalHotKeyController.identifier)

        #expect(actionCallCount == 1)
    }

    @Test("Registration failure is reported and can be retried")
    func registrationFailureIsReported() throws {
        let registry = FakeHotKeyRegistry(registerError: TestRegistrationError.failed)
        let controller = makeController(registry: registry)

        #expect(throws: TestRegistrationError.failed) {
            try controller.start()
        }

        registry.registerError = nil
        try controller.start()
        #expect(registry.registerCallCount == 2)
    }

    private func makeController(
        registry: FakeHotKeyRegistry,
        action: @escaping () -> Void = {}
    ) -> GlobalHotKeyController {
        GlobalHotKeyController(
            registry: registry,
            deliverOnMain: { $0() },
            action: action
        )
    }
}

private enum TestRegistrationError: Error, Equatable {
    case failed
}

private final class FakeHotKeyRegistry: GlobalHotKeyRegistering {
    var registerError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var identifier: GlobalHotKeyIdentifier?
    private(set) var keyCode: UInt32?
    private(set) var modifiers: UInt32?
    private var handler: ((GlobalHotKeyIdentifier) -> Void)?

    init(registerError: Error? = nil) {
        self.registerError = registerError
    }

    func register(
        identifier: GlobalHotKeyIdentifier,
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping (GlobalHotKeyIdentifier) -> Void
    ) throws {
        registerCallCount += 1
        if let registerError {
            throw registerError
        }
        self.identifier = identifier
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
    }

    func unregister() {
        unregisterCallCount += 1
        handler = nil
    }

    func emit(_ identifier: GlobalHotKeyIdentifier) {
        handler?(identifier)
    }
}
