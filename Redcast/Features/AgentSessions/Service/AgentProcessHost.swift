import AppKit

/// The agent's host app and tty from its pid: a sysctl walk up the parent chain.
enum AgentProcessHost {
    static let maxDepth = 16

    /// Inside tmux the walk ends at launchd, so the host stays unknown and only the tty is kept.
    nonisolated static func host(ofPID pid: Int32) -> (bundleID: String?, tty: String?) {
        guard pid > 1, let agent = info(pid) else { return (nil, nil) }
        let tty = ttyName(agent.device)
        var current = pid
        for _ in 0..<maxDepth {
            if let bundleID = NSRunningApplication(processIdentifier: current)?.bundleIdentifier {
                return (bundleID, tty)
            }
            guard let parent = info(current)?.parent, parent > 1, parent != current else { break }
            current = parent
        }
        return (nil, tty)
    }

    @concurrent static func hosting(_ pid: Int32?) async -> (bundleID: String?, tty: String?) {
        guard let pid else { return (nil, nil) }
        return host(ofPID: pid)
    }

    /// The probe's entries with their hosts filled in, so no row walks processes while it renders.
    @concurrent static func resolving(_ entries: [AgentLiveEntry]) async -> [AgentLiveEntry] {
        entries.map { entry in
            guard let pid = entry.pid else { return entry }
            var resolved = entry
            (resolved.hostBundleID, resolved.tty) = host(ofPID: pid)
            return resolved
        }
    }

    private static func info(_ pid: Int32) -> (parent: Int32, device: dev_t)? {
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &process, &size, nil, 0) == 0, size > 0 else { return nil }
        return (process.kp_eproc.e_ppid, process.kp_eproc.e_tdev)
    }

    private static func ttyName(_ device: dev_t) -> String? {
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        let text = String(cString: name)
        return AgentResumeCommand.isSafeTTY(text) ? text : nil
    }
}
