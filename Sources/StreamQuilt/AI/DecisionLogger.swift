import Foundation

/// Append-only JSONL decision log (R0 of docs/laya-judge-rl-plan.md): every
/// track classification, subject arbitration and track outcome lands in
/// `logs/decisions.jsonl` so judge quality can be measured offline and later
/// turned into DPO/GRPO training pairs. Called from the engine's main-runloop
/// paths only — never from the render hot path.
public final class DecisionLogger {
    private let handle: FileHandle?

    /// Creates parent directories as needed; appends when the file exists.
    /// Returns nil when the path is not writable (logging is best-effort).
    public init?(path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = handle?.seekToEndOfFile()
    }

    public func log(_ obj: [String: Any]) {
        guard let handle,
              var data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.sortedKeys])
        else { return }
        data.append(0x0A)
        handle.write(data)
    }

    deinit { try? handle?.close() }
}
