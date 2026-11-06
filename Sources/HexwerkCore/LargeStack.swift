import Foundation

/// Runs `body` on a fresh thread with a large stack and waits for it.
/// Swift concurrency threads have 512 KiB, too little for embedded engines
/// (wasmtime in YARA-X, JavaScriptCore) and deep recursion.
public func onLargeStack<R>(_ stackSize: Int = 64 << 20, _ body: () -> R) -> R {
    withoutActuallyEscaping(body) { body in
        var result: R?
        let job = StackJob { result = body() }
        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        defer { pthread_attr_destroy(&attr) }
        pthread_attr_setstacksize(&attr, stackSize)
        var tid: pthread_t?
        let ctx = Unmanaged.passUnretained(job).toOpaque()
        if pthread_create(&tid, &attr, { ctx in
            Unmanaged<StackJob>.fromOpaque(ctx).takeUnretainedValue().run?()
            return nil
        }, ctx) == 0, let tid {
            pthread_join(tid, nil)
        } else {
            job.run?()          // no thread: run here rather than fail
        }
        // Drop the closure before leaving withoutActuallyEscaping (it checks).
        job.run = nil
        return result!
    }
}

private final class StackJob {
    var run: (() -> Void)?
    init(_ run: @escaping () -> Void) { self.run = run }
}
