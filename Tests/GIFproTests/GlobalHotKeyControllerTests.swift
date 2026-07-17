import Carbon
import Testing
@testable import GIFpro

@MainActor
@Suite("Global hot key")
struct GlobalHotKeyControllerTests {
    @Test("Carbon callback context delivers on the main actor")
    func carbonCallbackContextDeliversOnMainActor() async {
        await confirmation("callback delivered") { callbackDelivered in
            let context = CarbonHotKeyCallbackContext()
            let identifier = GlobalHotKeyController.identifier
            context.configure(identifier: identifier) { _ in
                #expect(Thread.isMainThread)
                callbackDelivered()
            }

            await Task.detached {
                _ = context.dispatch(identifier)
            }.value
        }
    }

    @Test("Registry rejects a colliding event for an unrelated hot key ID")
    func registryRejectsUnrelatedHotKeyID() throws {
        let operations = FakeCarbonHotKeyOperations()
        let registry = CarbonHotKeyRegistry(operations: operations)
        var received: [GlobalHotKeyIdentifier] = []
        try registry.register(
            identifier: GlobalHotKeyController.identifier,
            keyCode: UInt32(kVK_ANSI_G),
            modifiers: UInt32(optionKey | cmdKey)
        ) {
            received.append($0)
        }

        let unrelated = GlobalHotKeyIdentifier(signature: 0x4F54_4852, id: 1)
        #expect(registry.handle(identifier: unrelated) == OSStatus(eventNotHandledErr))
        #expect(received.isEmpty)
        #expect(registry.handle(identifier: GlobalHotKeyController.identifier) == noErr)
        #expect(received == [GlobalHotKeyController.identifier])
        try registry.unregister()
    }

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

        try controller.stop()
        try controller.stop()

        #expect(registry.unregisterCallCount == 1)
    }

    @Test("A stopped controller does not unregister again during deinit")
    func stoppedControllerDeinitDoesNotUnregisterAgain() async throws {
        let registry = FakeHotKeyRegistry()
        var controller: GlobalHotKeyController? = makeController(registry: registry)
        try controller?.start()
        try controller?.stop()

        controller = nil
        await Task.yield()

        #expect(registry.unregisterCallCount == 1)
    }

    @Test("Controller keeps started state until teardown succeeds")
    func controllerRetriesFailedTeardown() throws {
        let registry = FakeHotKeyRegistry(unregisterErrors: [TestRegistrationError.failed, nil])
        let controller = makeController(registry: registry)
        try controller.start()

        #expect(throws: TestRegistrationError.failed) {
            try controller.stop()
        }
        try controller.stop()

        #expect(registry.unregisterCallCount == 2)
    }

    @Test("Stop and restart discard a queued callback from the prior registration")
    func queuedCallbackFromPriorRegistrationIsDiscarded() throws {
        let registry = FakeHotKeyRegistry()
        var queuedActions: [@MainActor @Sendable () -> Void] = []
        var actionCallCount = 0
        let controller = GlobalHotKeyController(
            registry: registry,
            deliverOnMain: { queuedActions.append($0) },
            action: { actionCallCount += 1 }
        )
        try controller.start()
        registry.emit(GlobalHotKeyController.identifier)

        try controller.stop()
        registry.emit(GlobalHotKeyController.identifier)
        try controller.start()
        queuedActions.removeFirst()()

        #expect(actionCallCount == 0)
        registry.emit(GlobalHotKeyController.identifier)
        queuedActions.removeFirst()()
        #expect(actionCallCount == 1)
    }

    @Test("Registry retains registration when native unregister fails")
    func registryRetriesFailedNativeUnregister() throws {
        let operations = FakeCarbonHotKeyOperations()
        operations.unregisterStatuses = [-50, noErr]
        let registry = CarbonHotKeyRegistry(operations: operations)
        try registerShortcut(in: registry)

        #expect(throws: GlobalHotKeyError.unregistrationFailed(-50)) {
            try registry.unregister()
        }
        #expect(operations.removeCallCount == 0)

        try registry.unregister()
        #expect(operations.unregisterCallCount == 2)
        #expect(operations.removeCallCount == 1)
    }

    @Test("Remove failure is reported without retrying an invalid handler ref")
    func removeFailureIsNotRetried() throws {
        let operations = FakeCarbonHotKeyOperations()
        operations.removeStatus = -51
        let registry = CarbonHotKeyRegistry(operations: operations)
        try registerShortcut(in: registry)

        #expect(throws: GlobalHotKeyError.eventHandlerRemovalFailed(-51)) {
            try registry.unregister()
        }
        operations.removeStatus = noErr
        try registry.unregister()

        #expect(operations.removeCallCount == 1)
    }

    @Test("Registration rollback reports handler removal failure")
    func registrationRollbackReportsRemovalFailure() {
        let operations = FakeCarbonHotKeyOperations()
        operations.registerStatus = -52
        operations.removeStatus = -53
        let registry = CarbonHotKeyRegistry(operations: operations)

        #expect(
            throws: GlobalHotKeyError.registrationRollbackFailed(
                registrationStatus: -52,
                removalStatus: -53
            )
        ) {
            try registerShortcut(in: registry)
        }
        #expect(operations.removeCallCount == 1)
    }

    @Test("Deinit unregisters an active shortcut")
    func deinitUnregistersActiveShortcut() async throws {
        try await confirmation("unregistered") { unregistered in
            let registry = FakeHotKeyRegistry()
            registry.onUnregister = { unregistered() }
            var controller: GlobalHotKeyController? = makeController(registry: registry)
            try controller?.start()

            controller = nil
            await Task.yield()
        }
    }

    @Test("Background release schedules teardown on the main actor")
    func backgroundReleaseSchedulesMainActorTeardown() async throws {
        try await confirmation("unregistered on main actor") { unregistered in
            let registry = FakeHotKeyRegistry()
            registry.onUnregister = {
                #expect(Thread.isMainThread)
                unregistered()
            }

            try await Task.detached {
                let controller = await MainActor.run {
                    GlobalHotKeyController(
                        registry: registry,
                        deliverOnMain: { $0() },
                        action: {}
                    )
                }
                try await controller.start()
            }.value
        }
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

    private func registerShortcut(in registry: CarbonHotKeyRegistry) throws {
        try registry.register(
            identifier: GlobalHotKeyController.identifier,
            keyCode: UInt32(kVK_ANSI_G),
            modifiers: UInt32(optionKey | cmdKey),
            handler: { _ in }
        )
    }
}

@MainActor
private final class FakeCarbonHotKeyOperations: CarbonHotKeyOperating {
    var installStatus = noErr
    var registerStatus = noErr
    var unregisterStatuses: [OSStatus] = [noErr]
    var removeStatus = noErr
    private(set) var unregisterCallCount = 0
    private(set) var removeCallCount = 0

    func installEventHandler(
        _ handler: EventHandlerUPP?,
        context: UnsafeMutableRawPointer
    ) -> (OSStatus, EventHandlerRef?) {
        (installStatus, EventHandlerRef(bitPattern: 0x1))
    }

    func registerHotKey(
        keyCode: UInt32,
        modifiers: UInt32,
        identifier: EventHotKeyID
    ) -> (OSStatus, EventHotKeyRef?) {
        (registerStatus, EventHotKeyRef(bitPattern: 0x2))
    }

    func unregisterHotKey(_ hotKey: EventHotKeyRef) -> OSStatus {
        unregisterCallCount += 1
        return unregisterStatuses.removeFirst()
    }

    func removeEventHandler(_ handler: EventHandlerRef) -> OSStatus {
        removeCallCount += 1
        return removeStatus
    }
}

private enum TestRegistrationError: Error, Equatable {
    case failed
}

private final class FakeHotKeyRegistry: GlobalHotKeyRegistering {
    var registerError: Error?
    var onUnregister: (() -> Void)?
    private var unregisterErrors: [Error?]
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var identifier: GlobalHotKeyIdentifier?
    private(set) var keyCode: UInt32?
    private(set) var modifiers: UInt32?
    private var handler: (@MainActor (GlobalHotKeyIdentifier) -> Void)?

    init(registerError: Error? = nil, unregisterErrors: [Error?] = []) {
        self.registerError = registerError
        self.unregisterErrors = unregisterErrors
    }

    func register(
        identifier: GlobalHotKeyIdentifier,
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping @MainActor (GlobalHotKeyIdentifier) -> Void
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

    func unregister() throws {
        unregisterCallCount += 1
        if !unregisterErrors.isEmpty, let error = unregisterErrors.removeFirst() {
            throw error
        }
        handler = nil
        onUnregister?()
    }

    func emit(_ identifier: GlobalHotKeyIdentifier) {
        handler?(identifier)
    }
}
