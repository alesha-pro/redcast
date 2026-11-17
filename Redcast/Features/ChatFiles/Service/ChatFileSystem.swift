import Foundation

/// The file system `ChatFileResolver` is handed: one `stat` per path, off the main actor.
enum ChatFileSystem {
    @concurrent
    static func resolve(_ request: ChatFileRequest) async -> ChatFileLinks {
        ChatFileResolver.resolve(request, stat: stat)
    }

    nonisolated static func stat(_ path: String) -> ChatFileStat? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else {
            return ChatFileStat(isExecutable: FileManager.default.isExecutableFile(atPath: path))
        }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey])
        return ChatFileStat(isDirectory: true, isPackage: values?.isPackage ?? false)
    }

    /// Looked up again at the click, since the file may have changed since the reply was shown.
    nonisolated static func item(at path: String) -> ChatFileItem? {
        stat(path).map { ChatFileItem(path: path, kind: ChatFileOpenPolicy.kind(of: path, $0)) }
    }
}
