import Foundation

/// Swift mirror of the event object in
/// `packages/event-schema/schemas/ingest-batch.schema.json`.
/// Raw measurements only: cost is always computed in the backend.
public struct VikingEvent: Codable, Equatable, Sendable {
    public let eventId: String
    public let ts: String
    public let category: Category
    public let execution: Execution
    public let resource: String?
    public let units: [String: Int]?
    public let compute: Compute?
    public let attrs: [String: AttrValue]?
    public let estimated: Bool?

    public enum Category: String, Codable, Sendable {
        case llmInference = "llm_inference"
        case llmRefusal = "llm_refusal"
        case ocr
        case gpuSample = "gpu_sample"
    }

    public enum Execution: String, Codable, Sendable {
        case api
        case onDevice = "on_device"
    }

    public struct Compute: Codable, Equatable, Sendable {
        public let durationMs: Int?
        public let computeUnit: ComputeUnit?
        public let energyMj: Int?
        public let energyEstimated: Bool?
        public let thermalState: ThermalState?

        public enum ComputeUnit: String, Codable, Sendable {
            case cpu, gpu, ane
        }

        public enum ThermalState: String, Codable, Sendable {
            case nominal, fair, serious, critical
        }

        enum CodingKeys: String, CodingKey {
            case durationMs = "duration_ms"
            case computeUnit = "compute_unit"
            case energyMj = "energy_mj"
            case energyEstimated = "energy_estimated"
            case thermalState = "thermal_state"
        }

        public init(
            durationMs: Int? = nil,
            computeUnit: ComputeUnit? = nil,
            energyMj: Int? = nil,
            energyEstimated: Bool? = nil,
            thermalState: ThermalState? = nil
        ) {
            self.durationMs = durationMs
            self.computeUnit = computeUnit
            self.energyMj = energyMj
            self.energyEstimated = energyEstimated
            self.thermalState = thermalState
        }
    }

    /// attrs values are scalars only (contract): string, number, or bool.
    public enum AttrValue: Codable, Equatable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let boolValue = try? container.decode(Bool.self) {
                self = .bool(boolValue)
            } else if let numberValue = try? container.decode(Double.self) {
                self = .number(numberValue)
            } else {
                self = .string(try container.decode(String.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case ts, category, execution, resource, units, compute, attrs, estimated
    }

    public init(
        eventId: String = UUID().uuidString.lowercased(),
        ts: String = ISO8601Timestamp.now(),
        category: Category,
        execution: Execution,
        resource: String? = nil,
        units: [String: Int]? = nil,
        compute: Compute? = nil,
        attrs: [String: AttrValue]? = nil,
        estimated: Bool? = nil
    ) {
        self.eventId = eventId
        self.ts = ts
        self.category = category
        self.execution = execution
        self.resource = resource
        self.units = units
        self.compute = compute
        self.attrs = attrs
        self.estimated = estimated
    }
}

/// Batch envelope for POST /v1/ingest.
struct IngestEnvelope: Codable {
    struct Sdk: Codable {
        let name: String
        let version: String
    }

    struct Device: Codable {
        let `class`: String
        let os: String
        let sessionId: String
        let installId: String

        enum CodingKeys: String, CodingKey {
            case `class`, os
            case sessionId = "session_id"
            case installId = "install_id"
        }
    }

    let sdk: Sdk
    let configVersion: Int
    let device: Device
    let events: [VikingEvent]

    enum CodingKeys: String, CodingKey {
        case sdk, device, events
        case configVersion = "config_version"
    }
}

public enum ISO8601Timestamp {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func now(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }
}

/// Stable per-install and per-process identifiers for the envelope.
enum DeviceIdentity {
    private static let installIdKey = "io.viking.install_id"
    static let sessionId = UUID().uuidString.lowercased()

    static func installId(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: installIdKey) {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: installIdKey)
        return created
    }

    static var deviceClass: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static var osDescription: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let name = "iOS"
        #elseif os(macOS)
        let name = "macOS"
        #else
        let name = "unknown"
        #endif
        return "\(name) \(version.majorVersion).\(version.minorVersion)"
    }
}
