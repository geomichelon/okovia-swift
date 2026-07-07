import Foundation

/// Debug logging. Prints event summaries when `debug: true` - and never
/// prompt/completion content: attrs are redacted before events reach
/// the logger, and the logger itself only prints structural fields.
struct VikingLogger {
    let enabled: Bool

    func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        print("[Viking] \(message())")
    }

    func event(_ event: VikingEvent) {
        guard enabled else { return }
        var parts = [
            "category=\(event.category.rawValue)",
            "execution=\(event.execution.rawValue)"
        ]
        if let resource = event.resource { parts.append("resource=\(resource)") }
        if let units = event.units, !units.isEmpty {
            let unitText = units.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            parts.append(unitText)
        }
        if let duration = event.compute?.durationMs { parts.append("duration_ms=\(duration)") }
        if event.estimated == true { parts.append("estimated=true") }
        print("[Viking] event \(parts.joined(separator: " "))")
    }
}
