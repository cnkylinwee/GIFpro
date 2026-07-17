import Foundation

final class FrameBackpressure: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var inUse = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard inUse < capacity else {
            return false
        }

        inUse += 1
        return true
    }

    func release() {
        let waiters: [CheckedContinuation<Void, Never>]

        lock.lock()
        guard inUse > 0 else {
            lock.unlock()
            return
        }

        inUse -= 1
        if inUse == 0 {
            waiters = drainWaiters
            drainWaiters.removeAll(keepingCapacity: true)
        } else {
            waiters = []
        }
        lock.unlock()

        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilDrained() async {
        await withCheckedContinuation { continuation in
            let shouldResumeImmediately: Bool

            lock.lock()
            if inUse == 0 {
                shouldResumeImmediately = true
            } else {
                drainWaiters.append(continuation)
                shouldResumeImmediately = false
            }
            lock.unlock()

            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }
}
