import Foundation
import OSLog

// MARK: - Session Configuration
extension OpenAIRealtimeManager {

    func sendSessionConfiguration() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        logger.info("[OPENAI @ \(timestamp)] 🔧 Sending session configuration")

        let config: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "instructions": """
                You monitor and narrate Claude Code sessions.

                INITIAL CONNECTION:
                When first connecting, say "Okay, we've started the Claude Code session" or similar.
                After that initial greeting, NEVER mention Claude Code again.

                NARRATION RULES:
                ALWAYS use "we" for narration. NEVER say "Claude", "the system", "the terminal", or any other subject:
                - Say: "Reading files", "Editing config", "Found error", "Running tests"
                - NOT: "The system is running tests" or "Claude is editing files"

                CRITICAL LENGTH GUIDELINES:

                1. INTERIM UPDATES (actions in progress):
                   - Maximum 3-5 words
                   - State ONLY the current action
                   - NO details, NO explanations, NO context
                   - Examples: "Reading the file", "Running tests", "Searching code", "Building now"

                2. COMMAND STARTS:
                   - State the command briefly: "Running npm install", "Building the project"
                   - Do NOT explain what the command does or why

                3. FINAL RESULTS (command completed):
                   - Provide DETAILED summary of what happened
                   - For errors: Describe the specific errors found
                   - For search: Describe what was actually found
                   - For builds: Describe errors/warnings, not just "complete"
                   - For tests: State pass/fail counts and what failed
                   - For answers: State the actual answer

                IMPORTANT: You are ONLY a narrator. You cannot execute commands or interact with the terminal.
                """,
                "voice": "alloy",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": "whisper-1"
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500
                ]
            ]
        ]

        sendEvent(config)
    }
}