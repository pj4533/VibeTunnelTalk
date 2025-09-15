# VibeTunnelTalk

<p align="center">
  <strong>Real-time voice narration and control for Claude Code sessions.</strong><br>
  VibeTunnelTalk brings voice interaction to your terminal, powered by OpenAI's Realtime API.
</p>

<p align="center">
  <a href="https://github.com/pj4533/VibeTunnelTalk/releases/latest"><img src="https://img.shields.io/badge/Download-macOS-blue" alt="Download"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green" alt="License"></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14.0+-red" alt="macOS 14.0+"></a>
  <a href="https://support.apple.com/en-us/HT211814"><img src="https://img.shields.io/badge/Apple%20Silicon-Universal-orange" alt="Apple Silicon"></a>
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#installation">Installation</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#architecture">Architecture</a> •
  <a href="#documentation">Documentation</a>
</p>

## Table of Contents

- [Why VibeTunnelTalk?](#why-vibetunneltalk)
- [Features](#features)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [VibeTunnel Integration](#vibetunnel-integration)
- [Building from Source](#building-from-source)
- [Development](#development)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

## Why VibeTunnelTalk?

Ever wanted to hear what Claude Code is doing in real-time? VibeTunnelTalk makes it happen with natural voice interaction.

VibeTunnelTalk is the perfect companion for Claude Code sessions, providing:
- Real-time narration of terminal activity
- Intelligent filtering of repetitive output
- Voice interaction capabilities (in development)

## Features

- **🎙️ Real-time Voice Narration** - Hear what's happening in your terminal as it happens
- **🤖 Claude Code Integration** - Special intelligence for Claude Code sessions with activity status
- **🧠 Smart Filtering** - Intelligently filters repetitive output to focus on what matters
- **⚡ Low Latency** - Sub-second response times with OpenAI's Realtime API
- **🔒 Secure Authentication** - JWT-based authentication with VibeTunnel server
- **📊 Buffer Snapshots** - Efficient polling-based architecture without ANSI parsing
- **🎵 High-Quality Audio** - 24kHz PCM16 audio for crystal-clear voice interaction
- **🍎 Native macOS** - Built with SwiftUI for seamless Mac integration
- **🗣️ Voice Input** - Voice command processing (in development)

## Installation

### Prerequisites

- macOS 14.0+ (Sonoma)
- [VibeTunnel](https://github.com/amantus-ai/vibetunnel) installed and running
- OpenAI API key with Realtime API access
- Active VibeTunnel session to monitor

### Download and Install

1. **Download VibeTunnelTalk** from the [latest release](https://github.com/pj4533/VibeTunnelTalk/releases/latest)
2. **Drag to Applications** folder
3. **Open VibeTunnelTalk** from Applications

### First Run Setup

1. **Configure OpenAI API Key**:
   - Open VibeTunnelTalk
   - Go to Settings → OpenAI
   - Enter your OpenAI API key
   - Key is securely stored in macOS Keychain

2. **Start VibeTunnel Session**:
   ```bash
   # Start a Claude Code session with VibeTunnel
   vt claude --dangerously-skip-permissions
   ```

3. **Connect VibeTunnelTalk**:
   - Select your session from the dropdown
   - Click "Start Voice" to begin narration
   - Use the microphone button for voice input

## Quick Start

### Basic Usage

1. **Launch VibeTunnel** and start a terminal session:
   ```bash
   vt --title-mode dynamic claude
   ```

2. **Open VibeTunnelTalk** and select your session

3. **Start Voice Interaction**:
   - Click "Start Voice" to begin narration
   - Use the microphone button for voice input

## Architecture

VibeTunnelTalk uses a simplified polling-based architecture that leverages VibeTunnel's server-side terminal processing:

### Core Components

- **VibeTunnelSocketManager**: Manages Unix domain socket connections to VibeTunnel IPC
- **VibeTunnelBufferService**: Polls VibeTunnel's buffer API every 500ms for terminal snapshots
- **SmartTerminalProcessor**: Intelligently processes changes and manages OpenAI communication
- **OpenAIRealtimeManager**: WebSocket connection to OpenAI's Realtime API for voice
- **VoiceCommandProcessor**: Maps voice intents to terminal commands

### Data Flow

1. **Terminal Buffer Polling**: Fetches complete terminal state from VibeTunnel every 500ms
2. **Change Detection**: Compares snapshots to detect meaningful changes
3. **Smart Filtering**: Removes repetitive patterns and focuses on important content
4. **Voice Generation**: Sends filtered changes to OpenAI for narration
5. **Command Processing**: Voice commands are processed and sent back to terminal

For detailed architecture information, see [Data Flow Architecture](docs/Data_Flow_Architecture.md).

## VibeTunnel Integration

VibeTunnelTalk communicates with VibeTunnel through two interfaces:

### IPC Socket (Control)
- Path: `~/.vibetunnel/control/{session-id}/ipc.sock`
- Protocol: Binary message format with 5-byte header
- Used for: Sending keyboard input and control commands

### Buffer API (State)
- Endpoint: `http://localhost:4020/api/sessions/{session-id}/buffer`
- Protocol: HTTP polling (500ms interval)
- Used for: Fetching complete terminal buffer snapshots

### Authentication
- JWT tokens for secure API access
- Token refresh before expiration
- Credentials stored in macOS Keychain

For complete VibeTunnel architecture details, see [VibeTunnel Architecture](docs/vibetunnel_architecture.md).


## Building from Source

### Prerequisites

- macOS 14.0+ (Sonoma)
- Xcode 16.0+
- Swift 6.0+

### Build Steps

```bash
# Clone the repository
git clone https://github.com/pj4533/VibeTunnelTalk.git
cd VibeTunnelTalk

# Build with xcodebuild
xcodebuild -project VibeTunnelTalk.xcodeproj \
           -scheme VibeTunnelTalk \
           -configuration Release \
           build

# Or open in Xcode
open VibeTunnelTalk.xcodeproj
```

### Code Signing

For distribution, you'll need to configure code signing:
1. Open project in Xcode
2. Select VibeTunnelTalk target
3. Update Team in Signing & Capabilities
4. Ensure "Automatically manage signing" is enabled

## Development

### Running Tests

```bash
# Run all tests
xcodebuild test -project VibeTunnelTalk.xcodeproj \
                -scheme VibeTunnelTalk \
                -destination 'platform=macOS'

# Run specific test class
xcodebuild test -project VibeTunnelTalk.xcodeproj \
                -scheme VibeTunnelTalk \
                -only-testing:VibeTunnelTalkTests/VibeTunnelSocketManagerTests
```

### Debug Logging

Enable detailed logging in the app:
1. Open Settings → Advanced
2. Enable "Debug Logging"
3. Logs are written to Console.app

### Project Structure

```
VibeTunnelTalk/
├── Managers/           # Core business logic
│   ├── VibeTunnelSocketManager.swift
│   ├── SmartTerminalProcessor.swift
│   ├── OpenAIRealtimeManager.swift
│   └── VoiceCommandProcessor.swift
├── Services/           # Network and data services
│   ├── VibeTunnelBufferService.swift
│   └── AuthenticationService.swift
├── Models/            # Data models
│   ├── BufferSnapshot.swift
│   ├── VibeTunnelMessage.swift
│   └── OpenAIRealtimeModels.swift
├── Views/             # SwiftUI views
│   ├── ContentView.swift
│   ├── SettingsView.swift
│   └── SessionListView.swift
└── Utils/             # Utilities and helpers
```

### Key Technologies

- **SwiftUI**: Native macOS user interface
- **Network.framework**: Unix domain socket communication
- **AVFoundation**: Audio capture and playback
- **URLSession**: WebSocket and HTTP networking
- **Combine**: Reactive programming for data flow

## Documentation

- [Implementation Guide](docs/VibeTunnelTalk_Implementation_Guide.md) - Detailed implementation reference
- [Data Flow Architecture](docs/Data_Flow_Architecture.md) - Complete data flow explanation
- [VibeTunnel Architecture](docs/vibetunnel_architecture.md) - VibeTunnel integration details

### Reference Projects

- **VibeTunnel**: Server implementation at `~/Developer/vibetunnel`
- **OpenAI Reference**: WebSocket implementation at `~/Developer/swift-realtime-openai`

## Contributing

We welcome contributions! Please feel free to submit issues and pull requests.

### Development Setup

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass
6. Submit a pull request

### Code Style

- Follow Swift API Design Guidelines
- Use SwiftLint for code formatting
- Add documentation comments for public APIs
- Keep commits focused and atomic

## Support

- **Issues**: [GitHub Issues](https://github.com/pj4533/VibeTunnelTalk/issues)
- **Discussions**: [GitHub Discussions](https://github.com/pj4533/VibeTunnelTalk/discussions)

## License

VibeTunnelTalk is open source software licensed under the MIT License. See [LICENSE](LICENSE) for details.

---

**Ready to talk to your terminal?** [Download VibeTunnelTalk](https://github.com/pj4533/VibeTunnelTalk/releases/latest) and start the conversation!