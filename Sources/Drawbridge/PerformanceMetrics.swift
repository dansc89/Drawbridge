import Foundation

struct PerformanceSpan {
    let name: String
    let startedAt: CFAbsoluteTime
    let thresholdMs: Double
    let fields: [String: String]
}

enum PerformanceMetrics {
    private static let envVar = "DRAWBRIDGE_PERF"
    private static let queue = DispatchQueue(label: "com.drawbridge.performance-metrics")
    private static let fileName = "performance.log"

    static func begin(_ name: String, thresholdMs: Double, fields: [String: String] = [:]) -> PerformanceSpan? {
        guard isEnabled else { return nil }
        return PerformanceSpan(name: name, startedAt: CFAbsoluteTimeGetCurrent(), thresholdMs: thresholdMs, fields: fields)
    }

    @discardableResult
    static func end(_ span: PerformanceSpan?, extra: [String: String] = [:]) -> Double {
        guard let span else { return 0 }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - span.startedAt) * 1000.0
        guard elapsedMs >= span.thresholdMs else { return elapsedMs }

        var payload = span.fields
        for (key, value) in extra {
            payload[key] = value
        }
        payload["event"] = span.name
        payload["elapsed_ms"] = String(format: "%.2f", elapsedMs)
        payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
        appendLogLine(fields: payload)
        return elapsedMs
    }

    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[envVar] == "1"
    }

    private static func appendLogLine(fields: [String: String]) {
        let line = fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let escaped = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
                return "\(key)=\(escaped)"
            }
            .joined(separator: " ")
            + "\n"
        guard let data = line.data(using: .utf8) else { return }

        queue.async {
            guard let url = logFileURL() else { return }
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func logFileURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("Drawbridge").appendingPathComponent("Logs")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent(fileName)
        } catch {
            return nil
        }
    }
}
