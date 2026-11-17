import Darwin
import Foundation

/// An agent's descendants, identified by pid and start time so a reused pid is never signalled.
nonisolated enum ProcessTree {
    struct Member: Equatable, Sendable {
        let pid: pid_t
        let started: UInt64
    }

    /// A cap that no real agent reaches; a runaway tree is still walked no further than this.
    private static let maxMembers = 512

    static func members(under root: pid_t) -> [Member] {
        var found: [Member] = []
        var queue = [root]
        while let parent = queue.popLast(), found.count < maxMembers {
            var buffer = [pid_t](repeating: 0, count: 256)
            let count = buffer.withUnsafeMutableBytes {
                proc_listchildpids(parent, $0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { continue }
            for pid in buffer.prefix(Int(min(count, 256))) where pid > 0 {
                guard let started = startTime(of: pid) else { continue }
                found.append(Member(pid: pid, started: started))
                queue.append(pid)
            }
        }
        return found
    }

    /// SIGTERM after a second's grace, SIGKILL two seconds later; only members still the same.
    static func reap(_ members: [Member], root: Process?) {
        guard !members.isEmpty || root != nil else { return }
        Task.detached {
            try? await Task.sleep(for: .seconds(1))
            if let root, root.isRunning { root.terminate() }
            for member in members where isAlive(member) { kill(member.pid, SIGTERM) }
            try? await Task.sleep(for: .seconds(2))
            if let root, root.isRunning { kill(root.processIdentifier, SIGKILL) }
            for member in members where isAlive(member) { kill(member.pid, SIGKILL) }
        }
    }

    static func isAlive(_ member: Member) -> Bool {
        startTime(of: member.pid) == member.started
    }

    private static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }
}
