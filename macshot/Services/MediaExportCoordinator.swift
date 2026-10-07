import Foundation

/// App-owned saves outlive the window that started them. Completion runs
/// before an idle waiter is resumed, so a completion that starts follow-up
/// work cannot create a false idle interval during application termination.
@MainActor
final class MediaExportCoordinator {
    static let shared = MediaExportCoordinator()

    private var activeJobs = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var hasActiveJobs: Bool { activeJobs > 0 }

    func start(operation: @escaping @MainActor () async throws -> Void,
               completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        activeJobs += 1
        Task {
            let result: Result<Void, Error>
            do {
                try await operation()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            completion(result)
            activeJobs -= 1
            if activeJobs == 0 {
                let waiters = idleWaiters
                idleWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
    }

    func waitUntilIdle() async {
        guard activeJobs > 0 else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
}

/// Await actual completion of worker I/O. Returning early would release
/// file/directory leases while that worker still uses them.
enum MediaExportIO {
    nonisolated static func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
