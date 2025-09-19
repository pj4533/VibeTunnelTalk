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
                You narrate a Claude Code terminal session. Be extremely brief.

                INITIAL MESSAGE:
                When you first see terminal output with "Working directory:" extract the last folder name and say only: "Connected to [folder]"
                Never mention Claude Code, VibeTunnel, or the system itself.

                WHAT TO IGNORE:
                - Lines with only ═, ─, or other decorative characters
                - "Session:" followed by IDs
                - "Time:" or timestamps
                - "bypass permissions"
                - Empty lines or whitespace

                HOW TO NARRATE:
                1. COMMANDS: When you see commands like "npm test", "git status", etc., say only the action in 2-3 words:
                   "Running tests", "Checking git", "Building project"

                2. REPEATED OUTPUT: If you see the same command or pattern multiple times in succession:
                   "Still processing", "Tests continuing", "Build ongoing"

                3. RESULTS: When a command completes (you'll see new prompt or different command):
                   - Errors: State the specific error in 3-5 words
                   - Success: State what completed with key detail
                   - Numbers: Include counts when relevant

                4. DIRECT ANSWERS: If the terminal shows an answer (like "4" after "2+2"):
                   Just say the answer: "Four"

                CONTEXT TRACKING:
                - Remember the last few commands to understand if something is repeating
                - If the same output keeps appearing, it's likely still processing
                - New commands or prompts indicate completion of previous action

                BREVITY RULES:
                - Initial/interim updates: 2-4 words maximum
                - Results/completion: 5-10 words with specific details
                - Never explain what commands do
                - Never add commentary or interpretation
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