import Foundation

/// Fork: a server's trust under a chat's Access level, which never lifts a server's Never Allow.
extension MCPTrustPolicy {
    static func decide(trust: MCPTrust, isGrantedForChat: Bool, access: ChatAccess) -> Verdict {
        switch (access, trust) {
        case (_, .never): .refuse
        case (.agentSettings, _): decide(trust: trust, isGrantedForChat: isGrantedForChat)
        case (.askEveryTime, _): .ask
        case (.allowEverything, _): .allow
        }
    }
}
