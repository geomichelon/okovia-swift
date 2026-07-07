import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Abstracts the HTTP send so tests can simulate failures/offline.
protocol IngestSending {
    /// Returns true when the batch was accepted (2xx).
    func send(body: Data, endpoint: URL, apiKey: String) async -> Bool
}

/// Pipeline: enqueue -> redact -> sample -> SQLite -> batch flush
/// (N events, X seconds, or app backgrounding) -> gzip -> POST with
/// exponential backoff on failure. Everything is config-driven and
/// reacts to remote config changes via `apply(_:)`.
final class EventQueue: ConfigApplying {
    private let store: SQLiteEventStore
    private let sender: IngestSending
    private let apiKey: String
    private let logger: VikingLogger
    private let workQueue = DispatchQueue(label: "io.viking.event-queue")

    private var config: RemoteConfig
    private var redactor: Redactor
    private var flushTimer: DispatchSourceTimer?
    private var consecutiveFailures = 0
    private var random: () -> Double

    private let encoder = JSONEncoder()

    init(
        store: SQLiteEventStore,
        sender: IngestSending,
        apiKey: String,
        config: RemoteConfig,
        logger: VikingLogger,
        random: @escaping () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.store = store
        self.sender = sender
        self.apiKey = apiKey
        self.config = config
        self.redactor = Redactor(config: config)
        self.logger = logger
        self.random = random
        scheduleFlushTimer()
        observeBackgrounding()
    }

    func apply(_ config: RemoteConfig) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.config = config
            self.redactor = Redactor(config: config)
            self.scheduleFlushTimer()
        }
    }

    /// Enqueues an event. Sampling and redaction happen here, BEFORE
    /// anything touches disk.
    func enqueue(_ event: VikingEvent) {
        workQueue.async { [weak self] in
            guard let self else { return }

            let samplingRate = self.config.transport.samplingRate ?? 1.0
            if samplingRate < 1.0, self.random() >= samplingRate {
                self.logger.debug("event sampled out (rate \(samplingRate)): \(event.category.rawValue)")
                return
            }

            let redacted = self.redactor.redact(event)
            do {
                let payload = try self.encoder.encode(redacted)
                let inserted = try self.store.insert(eventId: redacted.eventId, payload: payload)
                guard inserted else {
                    self.logger.debug("duplicate event_id ignored: \(redacted.eventId)")
                    return
                }
                self.logger.event(redacted)

                let maxBytes = self.config.transport.maxQueueBytes ?? 5_242_880
                let droppedCount = try self.store.trim(toMaxBytes: maxBytes)
                if droppedCount > 0 {
                    self.logger.debug("queue over max_queue_bytes; dropped \(droppedCount) oldest event(s)")
                }

                let batchMax = self.config.transport.batchMaxEvents ?? 50
                if try self.store.count() >= batchMax {
                    self.flushLocked(reason: "batch size reached")
                }
            } catch {
                self.logger.debug("enqueue failed: \(error)")
            }
        }
    }

    func flush(reason: String = "manual") {
        workQueue.async { [weak self] in
            self?.flushLocked(reason: reason)
        }
    }

    // MARK: - Internals (already on workQueue)

    private func flushLocked(reason: String) {
        if consecutiveFailures > 0 {
            // Exponential backoff: skip flushes while cooling down.
            let delay = backoffDelay(failures: consecutiveFailures)
            if let lastFailure = lastFailureAt, Date().timeIntervalSince(lastFailure) < delay {
                logger.debug("flush skipped (backoff \(Int(delay))s after \(consecutiveFailures) failure(s))")
                return
            }
        }

        let batchMax = config.transport.batchMaxEvents ?? 50
        guard let batch = try? store.oldest(limit: batchMax), !batch.isEmpty else { return }

        let events = batch.compactMap { stored -> VikingEvent? in
            try? JSONDecoder().decode(VikingEvent.self, from: stored.payload)
        }
        guard !events.isEmpty else {
            try? store.delete(rowIds: batch.map(\.rowId))
            return
        }

        let envelope = IngestEnvelope(
            sdk: .init(name: VikingSDKInfo.name, version: VikingSDKInfo.version),
            configVersion: config.configVersion,
            device: .init(
                class: DeviceIdentity.deviceClass,
                os: DeviceIdentity.osDescription,
                sessionId: DeviceIdentity.sessionId,
                installId: DeviceIdentity.installId()
            ),
            events: events
        )

        guard let body = try? encoder.encode(envelope),
              let compressed = try? Gzip.compress(body)
        else { return }

        logger.debug("flushing \(events.count) event(s) (\(reason))")

        let semaphore = DispatchSemaphore(value: 0)
        var accepted = false
        let sender = self.sender
        let endpoint = config.transport.endpoint
        let apiKey = self.apiKey
        Task.detached {
            accepted = await sender.send(body: compressed, endpoint: endpoint, apiKey: apiKey)
            semaphore.signal()
        }
        semaphore.wait()

        if accepted {
            consecutiveFailures = 0
            lastFailureAt = nil
            try? store.delete(rowIds: batch.map(\.rowId))
            logger.debug("flush accepted (\(events.count) event(s))")
        } else {
            consecutiveFailures += 1
            lastFailureAt = Date()
            logger.debug("flush failed; events kept for retry (failure #\(consecutiveFailures))")
        }
    }

    private var lastFailureAt: Date?

    func backoffDelay(failures: Int) -> TimeInterval {
        min(pow(2.0, Double(failures)), 300)
    }

    private func scheduleFlushTimer() {
        flushTimer?.cancel()
        let interval = TimeInterval(config.transport.flushIntervalS ?? 30)
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.flushLocked(reason: "interval")
        }
        timer.resume()
        flushTimer = timer
    }

    private func observeBackgrounding() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.flush(reason: "app backgrounded")
        }
        #elseif canImport(AppKit)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.flush(reason: "app resigning active")
        }
        #endif
    }

    /// Test hook: runs `body` after all queued work completes.
    func _drainForTesting() {
        workQueue.sync {}
    }
}

/// Production sender: gzip body, public key auth, X-SDK-Version on
/// every request (compat rule #5).
struct URLSessionIngestSender: IngestSending {
    let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func send(body: Data, endpoint: URL, apiKey: String) async -> Bool {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue(VikingSDKInfo.version, forHTTPHeaderField: VikingSDKInfo.versionHeader)

        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return (200...299).contains(http.statusCode)
    }
}
