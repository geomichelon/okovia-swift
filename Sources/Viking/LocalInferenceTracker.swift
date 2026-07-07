import Foundation

/// Real on-device energy measurement requires IOReport, a private API
/// that is not App Store-safe. The sampler is a protocol so a
/// power-metrics integration can slot in later; the default reports
/// "unavailable" and events carry energy_mj = null per contract.
protocol EnergySampling {
    /// Millijoules consumed during the sampled window, or nil when the
    /// platform cannot measure it.
    func measure<T>(_ body: () throws -> T) rethrows -> (result: T, energyMj: Int?)
}

struct UnavailableEnergySampler: EnergySampling {
    func measure<T>(_ body: () throws -> T) rethrows -> (result: T, energyMj: Int?) {
        (try body(), nil)
    }
}

/// Result handle passed to the `Viking.inference` closure so customer
/// code can report token counts produced during the run.
public final class InferenceMeasurement {
    public internal(set) var inputTokens: Int?
    public internal(set) var outputTokens: Int?

    public func setTokens(input: Int? = nil, output: Int? = nil) {
        if let input { inputTokens = input }
        if let output { outputTokens = output }
    }
}

/// Compute unit the caller declared for the run (MLComputeUnits cannot
/// be introspected post-hoc from Core ML, so it is declared up front).
public enum InferenceComputeUnit: String, Sendable {
    case cpu, gpu, ane

    var contractValue: VikingEvent.Compute.ComputeUnit {
        switch self {
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .ane: return .ane
        }
    }
}

/// Manual instrumentation for local inference (Core ML, MLX,
/// llama.cpp): measures duration, thermal state, energy when available,
/// and tokens via the measurement callback.
final class LocalInferenceTracker: ConfigApplying {
    private let queue: EventQueue
    private let energySampler: EnergySampling
    private var config: RemoteConfig

    init(queue: EventQueue, config: RemoteConfig, energySampler: EnergySampling) {
        self.queue = queue
        self.config = config
        self.energySampler = energySampler
    }

    func apply(_ config: RemoteConfig) {
        self.config = config
    }

    var isEnabled: Bool { config.collectors.llmLocal?.enabled ?? false }

    func track<T>(
        model: String,
        computeUnit: InferenceComputeUnit,
        feature: String?,
        body: (InferenceMeasurement) throws -> T
    ) rethrows -> T {
        guard isEnabled else {
            return try body(InferenceMeasurement())
        }

        let measurement = InferenceMeasurement()
        let start = DispatchTime.now()
        let captureEnergy = config.collectors.llmLocal?.captureEnergy ?? false

        let (result, energyMj): (T, Int?)
        if captureEnergy {
            (result, energyMj) = try energySampler.measure { try body(measurement) }
        } else {
            (result, energyMj) = (try body(measurement), nil)
        }

        let durationMs = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

        var units: [String: Int] = [:]
        if let input = measurement.inputTokens { units["input_tokens"] = input }
        if let output = measurement.outputTokens { units["output_tokens"] = output }

        let event = VikingEvent(
            category: .llmInference,
            execution: .onDevice,
            resource: model,
            units: units.isEmpty ? nil : units,
            compute: .init(
                durationMs: durationMs,
                computeUnit: computeUnit.contractValue,
                energyMj: energyMj,
                energyEstimated: energyMj == nil ? nil : false,
                thermalState: Self.currentThermalState()
            ),
            attrs: feature.map { ["feature": .string($0)] }
        )
        queue.enqueue(event)
        return result
    }

    static func currentThermalState() -> VikingEvent.Compute.ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}
