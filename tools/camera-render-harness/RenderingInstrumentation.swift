import Foundation
import OSLog

/// Instrumentation belongs to the renderer, independent of its host process.
nonisolated enum RenderingLog {
    static let rendering = Logger(subsystem: "net.melisma.NeuralImageKit", category: "Rendering")
}

nonisolated enum RenderingSignpost {
    static let rendering = OSSignposter(logger: RenderingLog.rendering)
}

extension Logger {
    nonisolated func noticeOperation(_ operation: String, phase: String, fields: [String: String] = [:]) {
        let pairs = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        notice("op=\(operation, privacy: .public) phase=\(phase, privacy: .public) \(pairs, privacy: .public)")
    }
}
