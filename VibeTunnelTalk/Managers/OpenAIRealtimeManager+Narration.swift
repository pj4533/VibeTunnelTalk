import Foundation
import OSLog

// MARK: - Narration Management
extension OpenAIRealtimeManager {

    /// Send text context about terminal activity
    func sendTerminalContext(_ context: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        // Queue the narration request
        narrationQueue.append(context)
        logger.info("[OPENAI @ \(timestamp)] 📥 Queued narration request (queue size: \(self.narrationQueue.count), isResponseInProgress: \(self.isResponseInProgress), activeResponseId: \(self.activeResponseId ?? "none"))")

        // Process queue if not currently processing a response
        processNarrationQueue()
    }

    /// Process the narration queue
    func processNarrationQueue() {
        // Create timestamp for logging
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        // Check if WebSocket is connected
        guard isConnected else {
            logger.debug("[OPENAI @ \(timestamp)] 🔌 Not connected, clearing narration queue")
            narrationQueue.removeAll()
            return
        }

        // Check if we can send a narration
        guard !isResponseInProgress else {
            logger.info("[OPENAI @ \(timestamp)] ⏸️ Response in progress (ID: \(self.activeResponseId ?? "none")), will retry when complete")
            // Don't schedule retry here - response.done will trigger processNarrationQueue
            return
        }

        guard !narrationQueue.isEmpty else {
            return
        }

        // Check if enough time has passed since last narration
        let timeSinceLastNarration = Date().timeIntervalSince(lastNarrationTime)

        // For the very first narration (when lastNarrationTime is ancient), don't wait
        let isFirstNarration = timeSinceLastNarration > 3600 // More than an hour means it's the first

        if !isFirstNarration && timeSinceLastNarration < minNarrationInterval {
            let waitTime = minNarrationInterval - timeSinceLastNarration
            logger.info("[OPENAI @ \(timestamp)] ⏱️ Waiting \(String(format: "%.1f", waitTime))s before next narration")
            // Schedule retry
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) { [weak self] in
                self?.processNarrationQueue()
            }
            return
        }

        // Combine all queued narrations into one comprehensive update
        let combinedContext = narrationQueue.joined(separator: "\n\n")
        narrationQueue.removeAll()

        // Mark as processing (must update @Published on main thread)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let timestamp = formatter.string(from: Date())
            self.logger.info("[OPENAI @ \(timestamp)] 🔄 Setting isResponseInProgress = true (was: \(self.isResponseInProgress))")
            self.isResponseInProgress = true
        }
        lastNarrationTime = Date()

        logger.info("[OPENAI @ \(timestamp)] 📤 Sending combined narration request (\(combinedContext.count) chars)")

        // Send the chunk with analysis request
        let event: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "system",
                "content": [
                    [
                        "type": "input_text",
                        "text": combinedContext
                    ]
                ]
            ]
        ]

        sendEvent(event)

        // Request both text and audio response with narration
        let responseEvent: [String: Any] = [
            "type": "response.create",
            "response": [
                "modalities": ["text", "audio"],
                "instructions": """
                    ALWAYS use "we". NEVER say "Claude", "the system", "the terminal", etc.

                    When output is minimal: 1-2 short sentences.
                    When output is substantial: Summarize the RESULTS in detail:
                    - For errors: Describe what the errors are
                    - For search results: Describe what was found
                    - For build output: Describe specific errors or warnings
                    - For answers: State the actual answer, not just "we found it"

                    Focus on WHAT happened, not just that something finished.
                    """
            ]
        ]
        logger.info("[OPENAI @ \(timestamp)] 🎤 Requesting narration response")
        sendEvent(responseEvent)
    }
}