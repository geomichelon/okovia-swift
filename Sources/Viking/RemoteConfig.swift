import Foundation

/// Codable mirror of `packages/event-schema/schemas/sdk-config.schema.json`.
///
/// Contract rules this type must uphold:
/// - Evolution is additive only: fields are never renamed or removed.
///   `JSONDecoder` ignores unknown keys by default, which is exactly the
///   required "SDK ignores unknown fields" behavior - do not switch to an
///   exhaustive decoding strategy.
/// - Every field beyond the required top-level ones is optional with a safe
///   fallback, so a minimal config still decodes.
/// - cost rules never appear here; cost is computed by the backend.
public struct RemoteConfig: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let configVersion: Int
    public let projectId: String
    public let environment: String
    public let collectors: Collectors
    public let transport: Transport
    public let privacy: Privacy

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case configVersion = "config_version"
        case projectId = "project_id"
        case environment
        case collectors
        case transport
        case privacy
    }

    public struct Collectors: Codable, Equatable, Sendable {
        public let llmApi: LlmApi?
        public let llmLocal: LlmLocal?
        public let gpuSampling: GpuSampling?
        public let ocr: Ocr?

        enum CodingKeys: String, CodingKey {
            case llmApi = "llm_api"
            case llmLocal = "llm_local"
            case gpuSampling = "gpu_sampling"
            case ocr
        }

        public struct LlmApi: Codable, Equatable, Sendable {
            public let enabled: Bool
            public let interceptHosts: [String]?
            public let capturePromptContent: Bool?
            public let estimateTokensOnMissingUsage: Bool?

            enum CodingKeys: String, CodingKey {
                case enabled
                case interceptHosts = "intercept_hosts"
                case capturePromptContent = "capture_prompt_content"
                case estimateTokensOnMissingUsage = "estimate_tokens_on_missing_usage"
            }
        }

        public struct LlmLocal: Codable, Equatable, Sendable {
            public let enabled: Bool
            public let frameworks: [String]?
            public let captureEnergy: Bool?

            enum CodingKeys: String, CodingKey {
                case enabled
                case frameworks
                case captureEnergy = "capture_energy"
            }
        }

        public struct GpuSampling: Codable, Equatable, Sendable {
            public let enabled: Bool
            public let intervalMs: Int?

            enum CodingKeys: String, CodingKey {
                case enabled
                case intervalMs = "interval_ms"
            }
        }

        public struct Ocr: Codable, Equatable, Sendable {
            public let enabled: Bool
        }
    }

    public struct Transport: Codable, Equatable, Sendable {
        public let endpoint: URL
        public let batchMaxEvents: Int?
        public let flushIntervalS: Int?
        public let samplingRate: Double?
        public let maxQueueBytes: Int?

        enum CodingKeys: String, CodingKey {
            case endpoint
            case batchMaxEvents = "batch_max_events"
            case flushIntervalS = "flush_interval_s"
            case samplingRate = "sampling_rate"
            case maxQueueBytes = "max_queue_bytes"
        }
    }

    public struct Privacy: Codable, Equatable, Sendable {
        public let redactFields: [String]?
        public let hashUserIds: Bool?

        enum CodingKeys: String, CodingKey {
            case redactFields = "redact_fields"
            case hashUserIds = "hash_user_ids"
        }
    }
}

extension RemoteConfig {
    /// Embedded safe defaults, used until the SDK manages to download a
    /// published config at least once. `configVersion` 0 is reserved for
    /// this state so the backend can tell default-driven traffic apart.
    ///
    /// "Safe" here means: intercept known LLM API hosts and measure local
    /// inference, but never capture prompt content, and keep the noisier
    /// collectors (GPU sampling, OCR) off until explicitly enabled.
    public static func embeddedDefaults(projectId: String) -> RemoteConfig {
        RemoteConfig(
            schemaVersion: 1,
            configVersion: 0,
            projectId: projectId,
            environment: "unconfigured",
            collectors: Collectors(
                llmApi: .init(
                    enabled: true,
                    interceptHosts: ["api.openai.com", "api.anthropic.com"],
                    capturePromptContent: false,
                    estimateTokensOnMissingUsage: true
                ),
                llmLocal: .init(enabled: true, frameworks: ["coreml", "mlx"], captureEnergy: true),
                gpuSampling: .init(enabled: false, intervalMs: 5000),
                ocr: .init(enabled: false)
            ),
            transport: Transport(
                endpoint: URL(string: "https://ingest.viking.io/v1/ingest")!,
                batchMaxEvents: 50,
                flushIntervalS: 30,
                samplingRate: 1.0,
                maxQueueBytes: 5_242_880
            ),
            privacy: Privacy(redactFields: ["prompt", "completion"], hashUserIds: true)
        )
    }

    public static func decode(from data: Data) throws -> RemoteConfig {
        try JSONDecoder().decode(RemoteConfig.self, from: data)
    }
}
