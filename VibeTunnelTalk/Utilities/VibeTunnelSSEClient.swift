import Foundation
import Combine
import OSLog

/// Server-Sent Events client for VibeTunnel terminal output streaming
class VibeTunnelSSEClient: NSObject {
    private let logger = AppLogger.network
    
    let terminalOutput = PassthroughSubject<String, Never>()
    
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var buffer = Data()
    
    override init() {
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
        
        // VibeTunnel's SSE endpoint
        let urlString = "http://localhost:\(port)/api/sessions/\(sessionId)/stream"
        guard let url = URL(string: urlString) else {
            logger.error("[SSE] ❌ Invalid URL: \(urlString)")
            return
        }
        
        logger.info("[SSE] 🔌 Connecting to SSE stream: \(urlString)")
        
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        
        // Try to get auth token from running VibeTunnel process
        if let authToken = getVibeTunnelAuthToken() {
            logger.info("[SSE] 🔑 Using local auth token from VibeTunnel process")
            request.setValue(authToken, forHTTPHeaderField: "x-vibetunnel-local")
        } else {
            logger.warning("[SSE] ⚠️ No auth token found, connection may fail")
        }
        
        task = session?.dataTask(with: request)
        task?.resume()
        
        logger.info("[SSE] ✅ SSE connection initiated for session: \(sessionId)")
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
                logger.debug("[SSE] 🔑 Found auth token: \(String(output.prefix(20)))...")
                return output
            }
        } catch {
            logger.error("[SSE] ❌ Failed to get auth token: \(error)")
        }
        
        return nil
    }
    
    /// Disconnect from the SSE stream
    func disconnect() {
        logger.info("[SSE] 🔌 Disconnecting from SSE stream")
        task?.cancel()
        task = nil
        buffer.removeAll()
    }
    
    private func processBuffer() {
        // SSE format: lines separated by \n, events separated by \n\n
        guard let text = String(data: buffer, encoding: .utf8) else { return }
        
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
            if event == ":ok" {
                logger.info("[SSE] ✅ Connection confirmed")
            } else if event == ":heartbeat" {
                logger.debug("[SSE] 💗 Heartbeat received")
            }
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
        
        // Handle different event types
        if eventType.isEmpty || eventType == "data" {
            // Terminal output data
            if !eventData.isEmpty {
                logger.debug("[SSE] 📺 Received terminal data: \(eventData.count) chars")
                
                // Parse JSON data if it's wrapped
                if let jsonData = eventData.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let content = json["data"] as? String {
                    // Wrapped in JSON
                    DispatchQueue.main.async {
                        self.terminalOutput.send(content)
                    }
                } else {
                    // Raw text data
                    DispatchQueue.main.async {
                        self.terminalOutput.send(eventData)
                    }
                }
            }
        } else {
            logger.debug("[SSE] 📨 Received event type: \(eventType)")
        }
    }
}

// MARK: - URLSessionDataDelegate
extension VibeTunnelSSEClient: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse {
            logger.info("[SSE] 📡 Response received: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode == 200 {
                logger.info("[SSE] ✅ SSE stream connected successfully")
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
        
        logger.debug("[SSE] 📥 Received \(data.count) bytes, buffer size: \(self.buffer.count)")
        
        processBuffer()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled {
                logger.info("[SSE] 🛑 Connection cancelled")
            } else {
                logger.error("[SSE] ❌ Connection error: \(error.localizedDescription)")
            }
        } else {
            logger.info("[SSE] 🏁 Connection completed")
        }
        
        buffer.removeAll()
    }
}