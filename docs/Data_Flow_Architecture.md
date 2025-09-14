# VibeTunnelTalk Data Flow Architecture

## Overview

VibeTunnelTalk creates a voice interface for Claude Code sessions by monitoring terminal output and enabling voice control. The application uses a simplified polling-based architecture that leverages VibeTunnel's server-side terminal processing capabilities.

## Architecture Components

### 1. Terminal Buffer Polling

VibeTunnelTalk connects to VibeTunnel sessions through two primary mechanisms:

#### IPC Socket (Control Channel)
- **Path**: `~/.vibetunnel/control/{session-id}/ipc.sock`
- **Purpose**: Sends keyboard input and control commands to the terminal
- **Protocol**: Binary message format with 5-byte header
- **Direction**: VibeTunnelTalk → VibeTunnel

#### Buffer API (Data Channel)
- **Endpoint**: `http://localhost:4020/api/sessions/{session-id}/buffer`
- **Purpose**: Fetches complete terminal state as structured data
- **Protocol**: HTTP polling with JSON/Binary response
- **Polling Rate**: Every 0.5 seconds
- **Direction**: VibeTunnel → VibeTunnelTalk

### 2. Buffer Snapshot Structure

VibeTunnel provides a complete terminal snapshot that includes:

```swift
struct BufferSnapshot {
    let cols: Int           // Terminal width in columns
    let rows: Int           // Terminal height in rows
    let viewportY: Int      // Current scroll position
    let cursorX: Int        // Cursor X position
    let cursorY: Int        // Cursor Y position
    let cells: [[BufferCell]] // 2D grid of terminal cells
}

struct BufferCell {
    let char: String        // The actual character
    let width: Int          // Character width (1 or 2 for wide chars)
    let fg: Int?           // Foreground color (ANSI palette index)
    let bg: Int?           // Background color (ANSI palette index)
    let attributes: Int?    // Text attributes (bold, italic, etc.)
}
```

This snapshot represents the **exact text content** displayed in Claude's terminal, with all formatting preserved. VibeTunnel handles all the complex ANSI escape sequence parsing, terminal emulation, and buffer management on the server side.

### 3. Smart Terminal Processing

The Smart Terminal Processor is the brain of the narration system, converting raw buffer snapshots into intelligent voice narration.

#### Processing Pipeline

1. **Buffer Reception**
   - `VibeTunnelBufferService` polls the buffer endpoint every 500ms
   - Receives complete `BufferSnapshot` with current terminal state
   - No need for ANSI parsing or terminal emulation

2. **Text Extraction**
   - Processor extracts plain text from the 2D cell grid
   - Preserves logical structure (lines, indentation)
   - Trims unnecessary whitespace while maintaining formatting

3. **Change Detection**
   - Compares current buffer content with previously sent content
   - Calculates character-level differences
   - Only processes changes exceeding minimum threshold (5 characters)

4. **Intelligent Filtering**
   - Skips updates when OpenAI is currently speaking
   - Accumulates changes during speech for later processing
   - Prevents overwhelming the voice interface with rapid changes

#### Data Reduction
The processor achieves significant data reduction:
- Only sends meaningful changes, not every buffer update
- Filters out UI chrome and redundant updates
- Typically achieves 80-90% reduction in data sent to OpenAI

### 4. Voice Narration Pipeline

Once significant changes are detected, they flow through the voice narration system.

#### OpenAI Integration
The processed terminal updates are sent to OpenAI's Realtime API:

1. **Context Formatting**: Terminal content is wrapped with context markers
2. **Intelligent Analysis**: OpenAI analyzes what Claude is doing
3. **Narrative Generation**: Creates appropriate voice narration
4. **Speech Synthesis**: Converts narration to natural speech

#### Narration Characteristics
- **Activity Awareness**: Recognizes when Claude is thinking, coding, debugging
- **Contextual Relevance**: Focuses on important changes, ignores noise
- **Natural Pacing**: Narrates at appropriate moments without interrupting
- **Concise Summaries**: Provides useful information without overwhelming detail

### 5. Voice Command Processing

The reverse flow enables voice control of Claude through natural speech.

#### Audio Pipeline
1. **Capture**: Mac's microphone captures voice at 24kHz PCM16 mono
2. **Streaming**: Audio streams continuously to OpenAI while speaking
3. **Recognition**: OpenAI converts speech to text in real-time
4. **Intent Analysis**: Determines what action the user wants

#### Command Execution
1. **Command Generation**: OpenAI creates appropriate terminal commands
2. **IPC Transmission**: Commands sent through Unix domain socket
3. **Terminal Injection**: VibeTunnel injects input into Claude's terminal
4. **Response Monitoring**: Buffer updates show command results

### 6. System Synchronization

The simplified architecture maintains synchronization through:

#### Polling Consistency
- Regular 500ms polling ensures timely updates
- Buffer snapshots provide complete state (no incremental updates needed)
- Cursor position and viewport tracked for context

#### Connection Management
- IPC socket for reliable command delivery
- HTTP polling with automatic retry on failure
- Graceful handling of connection loss

#### Response Coordination
- Updates queue while OpenAI is speaking
- Accumulated changes sent after speech completes
- Maintains conversational flow without interruption

## Data Flow Summary

The complete data flow creates a continuous feedback loop:

1. **Terminal State** → VibeTunnel maintains complete terminal buffer
2. **Buffer Polling** → VibeTunnelTalk fetches snapshots every 500ms
3. **Text Extraction** → Smart processor extracts plain text from cell grid
4. **Change Detection** → Identifies meaningful content changes
5. **Voice Narration** → OpenAI generates and speaks contextual narration
6. **Voice Commands** → User speech interpreted by OpenAI
7. **Command Execution** → Commands sent via IPC socket to terminal
8. **Terminal Update** → Claude responds, updating the buffer
9. **Cycle Continues** → Next poll captures the updated state

## Key Architecture Benefits

### Simplicity
- No complex ANSI parsing or terminal emulation needed
- VibeTunnel handles all terminal complexity server-side
- Clean separation between data fetching and processing

### Reliability
- Polling provides predictable, consistent updates
- Complete state in each snapshot (no state synchronization issues)
- Simple HTTP/socket protocols with clear error handling

### Performance
- Efficient binary buffer format when available
- Smart filtering reduces OpenAI API calls
- Polling interval balanced for responsiveness vs. overhead

### Maintainability
- Minimal code surface area
- Clear data flow with single source of truth
- Well-defined interfaces between components

## Technical Implementation

### Core Components

1. **VibeTunnelBufferService** (`Services/VibeTunnelBufferService.swift`)
   - Handles HTTP polling of buffer endpoint
   - Decodes both JSON and binary buffer formats
   - Publishes buffer updates via Combine

2. **SmartTerminalProcessor** (`Managers/SmartTerminalProcessor.swift`)
   - Subscribes to buffer updates
   - Extracts and compares text content
   - Manages communication with OpenAI

3. **VibeTunnelSocketManager** (`Managers/VibeTunnelSocketManager.swift`)
   - Manages IPC socket connection
   - Sends terminal input commands
   - Coordinates buffer service lifecycle

4. **OpenAIRealtimeManager** (`Managers/OpenAIRealtimeManager.swift`)
   - WebSocket connection to OpenAI Realtime API
   - Audio streaming and speech synthesis
   - Voice command processing

This architecture provides a robust, maintainable foundation for voice-controlled terminal interaction while leveraging VibeTunnel's powerful terminal processing capabilities.