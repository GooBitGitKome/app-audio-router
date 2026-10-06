import AppAudioRouterRealtime

/// Small C11 atomic storage for values shared between control and CoreAudio IOProc queues.
/// Allocation and destruction happen outside audio callbacks.
final class RealtimeAtomicUInt32: @unchecked Sendable {
    private let storage: UnsafeMutableRawPointer

    init(_ initialValue: UInt32 = 0) {
        guard let storage = aar_atomic_u32_create(initialValue) else {
            fatalError("Unable to allocate atomic audio state")
        }
        self.storage = storage
    }

    deinit {
        aar_atomic_u32_destroy(storage)
    }

    func load() -> UInt32 {
        aar_atomic_u32_load(storage)
    }

    func store(_ value: UInt32) {
        aar_atomic_u32_store(storage, value)
    }

    @discardableResult
    func increment() -> UInt32 {
        aar_atomic_u32_increment(storage)
    }
}
