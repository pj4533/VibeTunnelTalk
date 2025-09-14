# VibeTunnelTalk Data Flow Architecture

## Overview

VibeTunnelTalk is a macOS application that provides real-time voice narration and control for Claude Code sessions. It acts as an intelligent voice interface layer between you and Claude, monitoring what Claude is doing in the terminal and allowing you to control Claude through voice commands.

## Core Concept

The application doesn't create or manage its own terminal. Instead, it creates a "mirror" of an existing Claude Code terminal session running through VibeTunnel. By reconstructing and monitoring what's happening in Claude's terminal, the app can provide intelligent voice narration about Claude's activities and accept voice commands to control Claude.

## Data Flow Architecture

### 1. Connection Establishment

When VibeTunnelTalk connects to a VibeTunnel session, it establishes two separate communication channels:

#### IPC Socket Connection
- **Purpose**: Sends control commands TO the terminal where Claude is running
- **Location**: Unix domain socket at `~/.vibetunnel/control/{session-id}/ipc.sock`
- **Direction**: VibeTunnelTalk → VibeTunnel → Claude's terminal
- **Functions**:
  - Sending keyboard input (simulating typing)
  - Terminal control commands (resize, refresh)
  - Session management commands

#### SSE Stream Connection
- **Purpose**: Receives real-time terminal output FROM Claude Code
- **Location**: HTTP Server-Sent Events stream at `http://localhost:4020/api/sessions/{session-id}/stream`
- **Direction**: Claude's terminal → VibeTunnel → VibeTunnelTalk
- **Functions**:
  - Streaming terminal output as it happens
  - Terminal resize events
  - Session status updates

### 2. Virtual Terminal Buffer System

The heart of the data processing is the Virtual Terminal Buffer, which maintains a real-time representation of what's being displayed in Claude's terminal.

#### Buffer Characteristics
- **Structure**: A 2D grid of characters, exactly like a real terminal screen
- **Dimensions**: Typically 120 columns × 40 rows (adjustable based on actual terminal size)
- **Content**: Each cell contains a character plus its visual attributes (colors, bold, etc.)

#### Processing Pipeline
When data arrives from the SSE stream:
1. **ANSI Processing**: The raw terminal output contains ANSI escape codes for formatting and cursor control
2. **Buffer Updates**: These codes are interpreted to update the virtual buffer correctly
3. **State Tracking**: The buffer maintains cursor position, colors, and screen content
4. **Screen Operations**: Handles scrolling, clearing, and other terminal operations

This virtual buffer essentially reconstructs what Claude is "seeing" on screen at any given moment, allowing the app to understand the context of Claude's activities.

### 3. Intelligent Change Detection

The Smart Terminal Processor continuously monitors the virtual buffer to detect meaningful changes.

#### Sampling Strategy
- **Frequency**: Samples the buffer every second for responsive narration
- **Comparison**: Compares current buffer state with previously sent state
- **Diff Creation**: Generates a "diff" containing only what has changed

#### Filtering Logic
The processor applies intelligent filtering to focus on meaningful content:
- **Noise Reduction**: Filters out terminal UI chrome (borders, status bars)
- **Change Threshold**: Only processes changes above a minimum threshold
- **Content Focus**: Prioritizes actual output over formatting changes
- **Activity Detection**: Recognizes patterns indicating Claude's current activity

#### Optimization Benefits
- **Data Reduction**: Typically achieves 80-90% reduction in data sent to OpenAI
- **Context Preservation**: Maintains understanding of what's happening without overwhelming detail
- **Responsiveness**: Balances between immediate updates and avoiding information overload

### 4. Voice Narration Pipeline

Once significant changes are detected, they flow through the voice narration system.

#### OpenAI Integration
The processed terminal updates are sent to OpenAI's Realtime API, which:
1. **Context Understanding**: Analyzes the terminal changes to understand what Claude is doing
2. **Activity Recognition**: Identifies whether Claude is thinking, writing code, debugging, etc.
3. **Narrative Generation**: Creates appropriate voice narration based on the activity
4. **Speech Synthesis**: Converts the narration to natural-sounding speech

#### Narration Characteristics
- **Contextual Awareness**: Narration adapts based on what Claude is doing
- **Conciseness**: Provides useful information without overwhelming detail
- **Timing**: Narrates at appropriate moments without interrupting workflow
- **Intelligence**: Understands the difference between important events and routine output

### 5. Voice Command Processing

The reverse flow allows you to control Claude through voice commands.

#### Audio Capture
- **Source**: Mac's microphone captures your voice
- **Format**: Audio is captured as 24kHz PCM16 mono
- **Streaming**: Audio streams continuously to OpenAI while you're speaking

#### Command Interpretation
OpenAI's Realtime API processes your voice:
1. **Speech Recognition**: Converts speech to text
2. **Intent Understanding**: Determines what you want Claude to do
3. **Command Generation**: Creates appropriate terminal commands
4. **Response Generation**: Provides voice feedback about the action

#### Command Execution
Commands flow back through the IPC socket:
1. **Command Formatting**: Converts intent to actual terminal input
2. **Socket Transmission**: Sends through the IPC socket to VibeTunnel
3. **Terminal Injection**: VibeTunnel injects the input into Claude's terminal
4. **Execution**: Claude receives and responds to the command

### 6. Synchronization and State Management

The system maintains synchronization between multiple components:

#### Buffer State
- **Real-time Updates**: Buffer stays synchronized with actual terminal content
- **Change Tracking**: Maintains history of what's been sent to OpenAI
- **Accumulation**: When OpenAI is busy, changes accumulate for next update

#### Connection State
- **Health Monitoring**: Both connections are monitored for disconnections
- **Reconnection Logic**: Automatic reconnection attempts on connection loss
- **State Preservation**: Buffer state is maintained across brief disconnections

#### Response Coordination
- **Response Detection**: System detects when OpenAI is generating a response
- **Update Queuing**: Terminal updates queue while OpenAI is speaking
- **Intelligent Resumption**: Accumulated changes are sent once OpenAI is ready

## Data Flow Summary

The complete data flow creates a continuous feedback loop:

1. **Terminal Output** → VibeTunnel captures Claude's terminal output
2. **SSE Stream** → Output streams to VibeTunnelTalk via Server-Sent Events
3. **Buffer Reconstruction** → Virtual buffer maintains current terminal state
4. **Change Detection** → Smart processor identifies meaningful changes
5. **Voice Narration** → OpenAI generates and speaks contextual narration
6. **Voice Commands** → Your spoken commands are interpreted by OpenAI
7. **Command Execution** → Commands flow through IPC socket back to terminal
8. **Terminal Input** → Claude receives and responds to commands

This creates a seamless voice interface where you can hear what Claude is doing and control Claude through natural speech, all while Claude continues working in its normal terminal environment.

## Key Design Principles

### Minimal Intrusion
The system observes and controls without modifying Claude's environment. Claude operates normally in its terminal, unaware of the voice layer.

### Intelligent Filtering
Not everything needs narration. The system intelligently determines what's worth speaking about, avoiding information overload.

### Real-time Responsiveness
The one-second sampling rate balances responsiveness with efficiency, providing timely updates without overwhelming processing.

### Contextual Understanding
By maintaining a complete buffer representation, the system understands context and can provide meaningful narration rather than raw output.

### Bidirectional Flow
Voice commands and narration create a natural conversation flow, making terminal interaction more accessible and intuitive.

## Benefits of This Architecture

### Efficiency
- Significant data reduction through intelligent diffing
- Minimal resource usage through sampling strategy
- Optimized for real-time performance

### Flexibility
- Works with any VibeTunnel session
- Adapts to different terminal sizes and configurations
- Extensible for additional features

### Intelligence
- Understands context through buffer analysis
- Provides meaningful narration, not just text-to-speech
- Interprets natural language commands

### Reliability
- Robust connection management
- State preservation across disconnections
- Graceful degradation when components fail

This architecture creates a powerful bridge between the visual world of terminal interfaces and the auditory world of voice interaction, making Claude Code sessions more accessible and interactive through natural voice communication.