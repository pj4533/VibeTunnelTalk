import Foundation
import Combine
import OSLog

// MARK: - Event Handling
extension OpenAIRealtimeManager {

    func handleDataMessage(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                return
            }

            switch type {
            case "response.created":
                handleResponseCreated(json)

            case "response.done":
                handleResponseDone(json)

            case "response.audio.delta":
                handleResponseAudioDelta(json)

            case "response.audio_transcript.delta":
                handleResponseAudioTranscriptDelta(json)

            case "response.audio.done":
                handleResponseAudioDone(json)

            case "response.audio_transcript.done":
                handleResponseAudioTranscriptDone(json)

            case "response.text.delta":
                handleResponseTextDelta(json)

            case "response.text.done":
                handleResponseTextDone(json)

            case "response.function_call_arguments.delta":
                // Function calls removed - we're narration only
                break

            case "response.function_call_arguments.done":
                // Function calls removed - we're narration only
                break

            case "input_audio_buffer.speech_started":
                // User started speaking
                break

            case "input_audio_buffer.speech_stopped":
                // User stopped speaking
                break

            case "conversation.item.created":
                // New conversation item created
                break

            case "response.output_item.added":
                // New output item added to response
                logger.debug("[OPENAI] 📦 Output item added")

            case "response.content_part.added":
                // New content part added to response
                logger.debug("[OPENAI] 📄 Content part added")

            case "response.content_part.done":
                // Content part completed
                logger.debug("[OPENAI] ✅ Content part done")

            case "response.output_item.done":
                // Output item completed
                logger.debug("[OPENAI] ✅ Output item done")

            case "session.created":
                handleSessionCreated(json)

            case "session.updated":
                handleSessionUpdated(json)

            case "error":
                handleError(json)

            case "rate_limits.updated":
                handleRateLimitsUpdated(json)

            default:
                handleUnknownEventType(type, json: json)
            }

        } catch {
            logger.error("[OPENAI-RX] ❌ Failed to parse message: \(error.localizedDescription)")
        }
    }

    // MARK: - Event Handler Methods

    private func handleResponseCreated(_ json: [String: Any]) {
        // Track the response ID from the response object
        if let response = json["response"] as? [String: Any],
           let responseId = response["id"] as? String {
            activeResponseId = responseId
            statsLogger.recordResponseStarted()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let timestamp = formatter.string(from: Date())
                self.logger.info("[OPENAI @ \(timestamp)] 🔄 Setting isResponseInProgress = true from response.created (was: \(self.isResponseInProgress))")
                self.isResponseInProgress = true
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let timestamp = formatter.string(from: Date())
            logger.info("[OPENAI @ \(timestamp)] 🆔 Response started: \(responseId)")
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let timestamp = formatter.string(from: Date())
            logger.warning("[OPENAI @ \(timestamp)] ⚠️ Response created without ID")
        }
    }

    private func handleResponseDone(_ json: [String: Any]) {
        // Response completed
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        if let response = json["response"] as? [String: Any],
           let responseId = response["id"] as? String {
            statsLogger.recordResponseCompleted()
            logger.info("[OPENAI @ \(timestamp)] ✅ Response completed: \(responseId)")
            if responseId == activeResponseId {
                activeResponseId = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm:ss.SSS"
                    let timestamp = formatter.string(from: Date())
                    self.logger.info("[OPENAI @ \(timestamp)] 🔄 Setting isResponseInProgress = false (was: \(self.isResponseInProgress))")
                    self.isResponseInProgress = false
                    // Process any queued narrations immediately
                    self.processNarrationQueue()
                }
            } else {
                logger.warning("[OPENAI @ \(timestamp)] ⚠️ Response done for unknown ID: \(responseId), active: \(self.activeResponseId ?? "none")")
            }
        } else {
            // Response done without ID - still clear the flag
            logger.warning("[OPENAI @ \(timestamp)] ⚠️ Response done without ID, clearing flag")
            activeResponseId = nil
            DispatchQueue.main.async { [weak self] in
                self?.isResponseInProgress = false
                // Process any queued narrations
                self?.processNarrationQueue()
            }
        }
    }

    private func handleResponseAudioDelta(_ json: [String: Any]) {
        // Handle audio chunk - this is the actual audio data event
        // The delta field contains base64-encoded audio data
        if let delta = json["delta"] as? String,
           let decodedAudio = Data(base64Encoded: delta) {
            statsLogger.recordAudioChunk(bytes: decodedAudio.count)
            handleAudioChunk(decodedAudio)
        } else {
            logger.warning("[OPENAI] ⚠️ response.audio.delta received but no valid delta data found")
        }
    }

    private func handleResponseAudioTranscriptDelta(_ json: [String: Any]) {
        // Handle audio transcript chunk (not the audio itself)
        if let delta = json["delta"] as? String {
            statsLogger.recordTranscriptDelta(chars: delta.count)
            DispatchQueue.main.async {
                self.transcription += delta
            }
        }
    }

    private func handleResponseAudioDone(_ json: [String: Any]) {
        // Audio response complete
        logger.info("[OPENAI] 🎶 Audio response complete, playing buffered audio")
        playBufferedAudio()
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }

    private func handleResponseAudioTranscriptDone(_ json: [String: Any]) {
        // Audio transcript complete
        if let transcript = json["transcript"] as? String {
            logger.info("[OPENAI] 📝 Full transcript: \(transcript)")
            DispatchQueue.main.async {
                self.activityNarration.send(transcript)
                self.transcription = ""
            }
        }
    }

    private func handleResponseTextDelta(_ json: [String: Any]) {
        // Handle text response chunk
        if let delta = json["delta"] as? String {
            DispatchQueue.main.async {
                self.transcription += delta
            }
        }
    }

    private func handleResponseTextDone(_ json: [String: Any]) {
        // Text response complete
        if let text = json["text"] as? String {
            logger.info("[OPENAI] 📝 Text response: \(text)")
            DispatchQueue.main.async {
                self.activityNarration.send(text)
                self.transcription = ""
            }
        }
    }


    private func handleSessionCreated(_ json: [String: Any]) {
        // Session created successfully
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        logger.info("[OPENAI @ \(timestamp)] 🎯 Session created successfully")

        // Send initial greeting after session is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.sendTerminalContext("VibeTunnelTalk connected to Claude Code session. Ready to narrate terminal activity.")
        }
    }

    private func handleSessionUpdated(_ json: [String: Any]) {
        // Session updated successfully
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        logger.info("[OPENAI @ \(timestamp)] 🎯 Session updated successfully")
    }

    private func handleError(_ json: [String: Any]) {
        // Handle error
        if let error = json["error"] as? [String: Any] {
            statsLogger.recordError()
            logger.error("[OPENAI] 🚨 Error from OpenAI: \(error)")

            // Check error type and handle appropriately
            if let code = error["code"] as? String {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let timestamp = formatter.string(from: Date())

                switch code {
                case "conversation_already_has_active_response":
                    logger.info("[OPENAI @ \(timestamp)] ⚠️ Active response conflict - waiting for current response to complete")
                    // Don't clear the active response state, just wait longer
                    // The response.done event will clear it properly

                case "rate_limit_exceeded":
                    logger.error("[OPENAI @ \(timestamp)] 🚫 Rate limit exceeded - backing off")
                    // Clear state and wait longer before retrying
                    activeResponseId = nil
                    DispatchQueue.main.async { [weak self] in
                        self?.isResponseInProgress = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                        self?.processNarrationQueue()
                    }

                default:
                    logger.error("[OPENAI @ \(timestamp)] 🚨 Unhandled error code: \(code)")
                    // For unknown errors, reset state and retry
                    activeResponseId = nil
                    DispatchQueue.main.async { [weak self] in
                        self?.isResponseInProgress = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.processNarrationQueue()
                    }
                }
            }
        }
    }

    private func handleRateLimitsUpdated(_ json: [String: Any]) {
        // Handle rate limits update - only log if there's an issue
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        // Parse the rate limit details and only warn if needed
        if let rateLimits = json["rate_limits"] as? [[String: Any]] {
            for rateLimit in rateLimits {
                if let name = rateLimit["name"] as? String,
                   let limit = rateLimit["limit"] as? Int,
                   let remaining = rateLimit["remaining"] as? Int,
                   let resetSeconds = rateLimit["reset_seconds"] as? Double {

                    let percentUsed = Double(limit - remaining) / Double(limit) * 100

                    if remaining == 0 {
                        // Log full details when exhausted
                        logger.error("[OPENAI @ \(timestamp)] 🚫 RATE LIMIT EXHAUSTED: \(name) - 0/\(limit) remaining, resets in \(resetSeconds)s")
                        logger.error("[OPENAI @ \(timestamp)] Response state - isResponseInProgress: \(self.isResponseInProgress), activeResponseId: \(self.activeResponseId ?? "none")")
                    } else if percentUsed > 90 {
                        // Only warn when usage is very high (>90%)
                        logger.warning("[OPENAI @ \(timestamp)] ⚠️ Rate limit high usage: \(name) - \(remaining)/\(limit) remaining (\(String(format: "%.1f", percentUsed))% used), resets in \(resetSeconds)s")
                    }
                    // Don't log anything for normal usage
                }
            }
        }
    }

    private func handleUnknownEventType(_ type: String, json: [String: Any]) {
        // Log unhandled message types with more detail
        logger.warning("[OPENAI] ⚠️ Unhandled message type: \(type)")
        // Log if this unhandled event contains audio-like data
        if let delta = json["delta"] as? String {
            logger.warning("[OPENAI] ⚠️ Event '\(type)' contains delta field with \(delta.count) characters")
            if let _ = Data(base64Encoded: delta) {
                logger.warning("[OPENAI] ⚠️ Delta appears to be valid base64 audio data!")
            }
        }
    }
}