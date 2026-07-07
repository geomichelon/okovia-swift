import Foundation

/// Removes sensitive keys from event attrs before anything is persisted.
///
/// Two layers, applied before an event ever reaches the SQLite queue:
/// - a hard-coded blocklist that can never be turned off (prompt and
///   completion content must not leave the process, even in debug mode);
/// - the remote config's `privacy.redact_fields`, so a customer can add
///   their own fields without an app release.
struct Redactor {
    static let alwaysRedacted: Set<String> = [
        "prompt", "completion", "prompt_text", "completion_text",
        "messages", "system_prompt", "input_text", "output_text"
    ]

    private let redactedKeys: Set<String>

    init(config: RemoteConfig) {
        let configured = config.privacy.redactFields ?? []
        redactedKeys = Self.alwaysRedacted.union(configured.map { $0.lowercased() })
    }

    func redact(_ attrs: [String: VikingEvent.AttrValue]?) -> [String: VikingEvent.AttrValue]? {
        guard let attrs else { return nil }
        let kept = attrs.filter { !redactedKeys.contains($0.key.lowercased()) }
        return kept.isEmpty ? nil : kept
    }

    func redact(_ event: VikingEvent) -> VikingEvent {
        VikingEvent(
            eventId: event.eventId,
            ts: event.ts,
            category: event.category,
            execution: event.execution,
            resource: event.resource,
            units: event.units,
            compute: event.compute,
            attrs: redact(event.attrs),
            estimated: event.estimated
        )
    }
}
