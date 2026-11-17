import SwiftUI

extension View {
    /// TCC announces nothing, so a pane asks while it is open; its status calls are blocking XPC.
    func pollingPermissions<Status: Equatable & Sendable>(
        read: @escaping @Sendable () -> Status,
        apply: @escaping @MainActor (Status) -> Void
    ) -> some View {
        task {
            while !Task.isCancelled {
                let status = await PermissionPolling.read(read)
                guard !Task.isCancelled else { return }
                apply(status)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private enum PermissionPolling {
    @concurrent static func read<Status: Sendable>(_ read: @Sendable () -> Status) async -> Status {
        read()
    }
}
