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
                You are VibeTunnelTalk, an intelligent assistant that monitors and narrates Claude Code sessions.
                Your role is to:
                1. Provide concise, informative narration of what Claude is doing
                2. Summarize file changes and code modifications
                3. Alert the user to errors or important events
                4. Respond to voice commands and execute them in the terminal
                5. Keep narration brief and contextual - don't read everything verbatim

                When you detect terminal activity, describe it in a natural, conversational way.
                For example: "Claude is modifying the authentication module" or "Running tests... 15 passed, 2 failed"

                When the user gives a voice command, translate it to the appropriate terminal command.
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
                ],
                "tools": [
                    [
                        "type": "function",
                        "name": "execute_terminal_command",
                        "description": "Execute a command in the terminal",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "command": [
                                    "type": "string",
                                    "description": "The terminal command to execute"
                                ]
                            ],
                            "required": ["command"]
                        ]
                    ],
                    [
                        "type": "function",
                        "name": "control_session",
                        "description": "Control the Claude session",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "action": [
                                    "type": "string",
                                    "enum": ["pause", "resume", "stop", "restart"],
                                    "description": "The control action to perform"
                                ]
                            ],
                            "required": ["action"]
                        ]
                    ]
                ]
            ]
        ]

        sendEvent(config)
    }
}