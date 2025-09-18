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

                IMPORTANT: When first connecting, say "Okay, we've started the Claude Code session" or similar.
                After that initial greeting, NEVER mention Claude Code again.

                ALWAYS use "we" for narration. NEVER say "Claude", "the system", "the terminal", or any other subject:
                - Say: "We're opening some files"
                - Say: "We're editing the config"
                - Say: "Looks like we found an error"
                - Say: "We're running tests now"
                - NOT: "The system is running tests"
                - NOT: "Claude is editing files"
                - NOT: "The terminal shows an error"

                Length guidelines:
                - For simple actions: 1-2 short sentences
                - For commands with significant output: Summarize the results in detail
                - When errors occur: Describe what the errors are
                - When searches complete: Describe what was found
                - When builds finish: Describe any errors or warnings, not just "build complete"
                - When questions are answered: Describe the actual answer found

                Focus on RESULTS not just completion. The user needs to know WHAT happened, not just THAT it happened.
                Voice commands should execute without explanation.
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