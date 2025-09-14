import Foundation
import Combine
import OSLog

/// Represents an asciinema event from VibeTunnel
struct AsciinemaEvent {
    let timestamp: Double
    let type: EventType
    let data: String

    enum EventType: String {
        case output = "o"
        case input = "i"
        case resize = "r"
        case exit = "exit"
    }
}

/// Server-Sent Events client for VibeTunnel terminal output streaming
class VibeTunnelSSEClient: NSObject {
    private let logger = AppLogger.network
    private let debouncedLogger: DebouncedLogger

    let terminalOutput = PassthroughSubject<String, Never>()
    let asciinemaEvent = PassthroughSubject<AsciinemaEvent, Never>()

    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var buffer = Data()

    // Track session start time for relative timestamps
    private var sessionStartTime: Date?

    // For periodic logging to detect stalled streams
    private var lastDataReceivedTime = Date()
    private var totalBytesReceived = 0
    
    override init() {
        self.debouncedLogger = DebouncedLogger(logger: AppLogger.network)
        super.init()
        
        // Create a custom URLSession with delegate
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 0 // No timeout for SSE
        configuration.timeoutIntervalForResource = 0
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    
    /// Connect to the SSE stream for a session
    func connect(sessionId: String, port: Int = 4020) {
        disconnect() // Ensure we're not already connected

        // Reset session start time
        sessionStartTime = Date()

        // VibeTunnel's SSE endpoint
        let urlString = "http://localhost:\(port)/api/sessions/\(sessionId)/stream"
        guard let url = URL(string: urlString) else {
            logger.error("[SSE] ❌ Invalid URL: \(urlString)")
            return
        }

        logger.info("[SSE] 🌐 Connecting to SSE stream at: \(urlString)")
        
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        
        // Try to get auth token from running VibeTunnel process
        if let authToken = getVibeTunnelAuthToken() {
            logger.info("[SSE] Using auth token: \(authToken)")
            request.setValue(authToken, forHTTPHeaderField: "x-vibetunnel-local")
        } else {
            logger.warning("[SSE] No auth token found, connection may fail")
        }
        
        task = session?.dataTask(with: request)
        task?.resume()
        
        // SSE connection initiated
    }
    
    /// Get the auth token from running VibeTunnel process
    private func getVibeTunnelAuthToken() -> String? {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "ps aux | grep vibetunnel | grep -o '\\-\\-local-auth-token [^ ]*' | head -1 | cut -d' ' -f2"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                // Found auth token
                return output
            }
        } catch {
            // Failed to get auth token
        }
        
        return nil
    }
    
    /// Disconnect from the SSE stream
    func disconnect() {
        task?.cancel()
        task = nil
        buffer.removeAll()
    }
    
    private func processBuffer() {
        // SSE format: lines separated by \n, events separated by \n\n
        guard let text = String(data: buffer, encoding: .utf8) else {
            logger.debug("[SSE] Unable to decode buffer as UTF-8")
            return
        }

        // Don't log buffer processing - too noisy

        // Split by double newline to get complete events
        let events = text.components(separatedBy: "\n\n")
        
        // Keep the last incomplete event in the buffer
        if !text.hasSuffix("\n\n") && events.count > 1 {
            // Keep the last incomplete event
            let lastEvent = events.last ?? ""
            buffer = lastEvent.data(using: .utf8) ?? Data()
            
            // Process all complete events
            for i in 0..<(events.count - 1) {
                processEvent(events[i])
            }
        } else if text.hasSuffix("\n\n") {
            // All events are complete
            buffer.removeAll()
            for event in events where !event.isEmpty {
                processEvent(event)
            }
        }
    }
    
    private func processEvent(_ event: String) {
        // Skip heartbeats and connection confirmations
        if event.hasPrefix(":") {
            // Skip heartbeats and connection confirmations
            return
        }

        // Parse SSE event
        var eventType = ""
        var eventData = ""

        let lines = event.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("event:") {
                eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if !eventData.isEmpty {
                    eventData += "\n"
                }
                eventData += data
            }
        }

        // Don't log every event - it's too noisy

        // Handle different event types
        if eventType.isEmpty || eventType == "data" {
            // Terminal output data - should be asciinema JSON
            if !eventData.isEmpty {
                parseAsciinemaEvent(eventData)
            }
        } else {
            // Other event type
            logger.debug("[SSE] Unhandled event type: \(eventType)")
        }
    }

    /// Parse asciinema JSON event
    private func parseAsciinemaEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }

        do {
            // Try to parse as JSON array (asciinema format)
            if let json = try JSONSerialization.jsonObject(with: data) as? [Any] {
                // Check if it's a header (has version field)
                if let header = json as? [String: Any],
                   let _ = header["version"] as? Int {
                    // This is the header, contains terminal dimensions
                    if let cols = header["width"] as? Int,
                       let rows = header["height"] as? Int {
                        logger.debug("[SSE] Terminal dimensions: \(cols)x\(rows)")
                    }
                    return
                }

                // Handle exit event [exit, code, timestamp]
                if let first = json.first as? String, first == "exit" {
                    if json.count >= 2, let exitCode = json[1] as? Int {
                        logger.info("[SSE] Session exited with code: \(exitCode)")
                    }
                    return
                }

                // Standard asciinema event: [timestamp, type, data]
                if json.count >= 3,
                   let timestamp = json[0] as? Double,
                   let typeStr = json[1] as? String,
                   let data = json[2] as? String {

                    // Create AsciinemaEvent
                    if let eventType = AsciinemaEvent.EventType(rawValue: typeStr) {
                        let event = AsciinemaEvent(
                            timestamp: timestamp,
                            type: eventType,
                            data: data
                        )

                        // Don't log every parsed event

                        // Emit events directly without main queue dispatch to avoid blocking
                        // Subscribers should handle their own thread management
                        self.asciinemaEvent.send(event)

                        // For backward compatibility, also send output events as raw text
                        if eventType == .output {
                            self.terminalOutput.send(data)
                        }
                    }
                }
            } else if let header = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Alternative header format (object with version)
                if let _ = header["version"] as? Int {
                    if let cols = header["width"] as? Int,
                       let rows = header["height"] as? Int {
                        logger.debug("[SSE] Terminal dimensions: \(cols)x\(rows)")
                    }
                }
            }
        } catch {
            // If not JSON, treat as raw text (fallback)
            // Send directly without main queue dispatch to avoid blocking
            self.terminalOutput.send(jsonString)
        }
    }
}

// MARK: - URLSessionDataDelegate
extension VibeTunnelSSEClient: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 200 {
                logger.info("[SSE] ✅ Connected")
                completionHandler(.allow)
            } else {
                logger.error("[SSE] ❌ Failed to connect: HTTP \(httpResponse.statusCode)")
                completionHandler(.cancel)
            }
        } else {
            completionHandler(.allow)
        }
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Append to buffer and process
        buffer.append(data)

        // Track data reception
        let now = Date()
        let timeSinceLastData = now.timeIntervalSince(lastDataReceivedTime)
        totalBytesReceived += data.count

        // Only log if it's been more than 5 seconds since last data (to detect stalls)
        // or every 100KB of data
        if timeSinceLastData > 5.0 || totalBytesReceived > 100_000 {
            let timestamp = DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .medium)
            logger.debug("[SSE @ \(timestamp)] Stream active: \(self.totalBytesReceived) total bytes received")
            totalBytesReceived = 0
        }

        lastDataReceivedTime = now

        // Use debounced logging for data flow
        debouncedLogger.logDataFlow(key: "SSE", bytes: data.count, action: "Receiving data")
        processBuffer()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).code != NSURLErrorCancelled {
                logger.error("[SSE] ❌ Connection error: \(error.localizedDescription)")
            }
        }
        
        buffer.removeAll()
    }
}