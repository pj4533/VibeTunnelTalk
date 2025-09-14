import Foundation
import OSLog

/// A logger that debounces repetitive log messages to reduce noise
class DebouncedLogger {
    private let logger: Logger
    private let debounceInterval: TimeInterval

    private var lastLogTimes: [String: Date] = [:]
    private var messageCounters: [String: Int] = [:]
    private var pendingMessages: [String: String] = [:]
    private let queue = DispatchQueue(label: "debounced.logger", attributes: .concurrent)
    private var timers: [String: Timer] = [:]

    init(logger: Logger, debounceInterval: TimeInterval = 2.0) {
        self.logger = logger
        self.debounceInterval = debounceInterval
    }

    /// Log a message with debouncing for the given key
    func logDebounced(key: String, initialMessage: String, continuationMessage: String? = nil) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            let now = Date()

            // Check if we've logged this key recently
            if let lastTime = self.lastLogTimes[key] {
                let timeSinceLastLog = now.timeIntervalSince(lastTime)

                if timeSinceLastLog < self.debounceInterval {
                    // Still within debounce window - increment counter
                    self.messageCounters[key, default: 0] += 1

                    // Cancel existing timer if any
                    self.timers[key]?.invalidate()

                    // Set up a timer to log summary when activity stops
                    let timer = Timer.scheduledTimer(withTimeInterval: self.debounceInterval, repeats: false) { _ in
                        self.queue.async(flags: .barrier) {
                            if let count = self.messageCounters[key], count > 0 {
                                let summaryMessage = continuationMessage ?? "(\(count + 1) similar events)"
                                self.logger.debug("[\(key)] \(summaryMessage)")
                                self.messageCounters[key] = 0
                            }
                        }
                    }
                    self.timers[key] = timer
                    return
                }
            }

            // First message or outside debounce window - log immediately
            self.logger.debug("[\(key)] \(initialMessage)")
            self.lastLogTimes[key] = now
            self.messageCounters[key] = 0
        }
    }

    /// Log data flow with smart summarization
    func logDataFlow(key: String, bytes: Int, action: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            let now = Date()
            let messageKey = "\(key)_dataflow"

            // Track cumulative bytes
            var cumulativeBytes = self.messageCounters[messageKey] ?? 0
            cumulativeBytes += bytes
            self.messageCounters[messageKey] = cumulativeBytes

            // Cancel any existing timer
            self.timers[messageKey]?.invalidate()

            // Set up a timer to log accumulated data after a pause
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                self.queue.async(flags: .barrier) {
                    if let totalBytes = self.messageCounters[messageKey], totalBytes > 0 {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "HH:mm:ss"
                        let timestamp = formatter.string(from: Date())

                        // Format bytes nicely
                        let formattedBytes = self.formatBytes(totalBytes)
                        self.logger.debug("[\(key) @ \(timestamp)] \(action): \(formattedBytes)")

                        self.messageCounters[messageKey] = 0
                        self.lastLogTimes[messageKey] = Date()
                    }
                }
            }
            self.timers[messageKey] = timer
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) bytes"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.2f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }

    /// Clean up timers
    deinit {
        queue.sync(flags: .barrier) {
            timers.values.forEach { $0.invalidate() }
            timers.removeAll()
        }
    }
}