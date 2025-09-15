# VibeTunnel Architecture Documentation

## Overview

VibeTunnel is a modern terminal multiplexer with native macOS and iOS applications, featuring a Node.js/Bun-powered server backend and real-time web interface. This document focuses on the architectural aspects relevant to VibeTunnelTalk integration, particularly the terminal session management, buffer snapshot API, and Claude Code forwarding capabilities.

## System Components

### 1. VibeTunnel macOS Application

The native macOS menu bar application serves as the central hub for VibeTunnel operations:

**Location**: `~/Developer/vibetunnel/mac/`

**Key Responsibilities**:
- **Server Lifecycle Management**: The `ServerManager` class (`mac/VibeTunnel/Core/Services/ServerManager.swift`) spawns and manages the Bun server process
- **Port Management**: Defaults to port 4020, configurable through settings
- **Process Monitoring**: Tracks server health, handles crashes with automatic restart
- **Authentication**: Manages local auth tokens stored in macOS Keychain
- **Network Configuration**: Controls bind address (localhost vs LAN access)

**Important**: The macOS app MUST be running for VibeTunnel to function. It's responsible for:
1. Starting the Bun/Node.js server process on startup
2. Managing the server lifecycle (start, stop, restart)
3. Providing the HTTP API endpoints at `http://localhost:4020`
4. Creating control sockets for IPC communication

### 2. VibeTunnel Server (Bun/Node.js)

The JavaScript/TypeScript server that handles all terminal operations:

**Location**: `~/Developer/vibetunnel/web/src/server/`

**Core Components**:
- `server.ts`: HTTP server initialization
- `app.ts`: Express application setup
- `pty/pty-manager.ts`: Native PTY process management
- `services/terminal-manager.ts`: Terminal buffer and state management
- `routes/sessions.ts`: REST API endpoints

**Server Startup Process**:
1. macOS app spawns Bun process with embedded server bundle
2. Server starts on configured port (default 4020)
3. Health check endpoint becomes available at `/api/health`
4. Server ready to accept session creation requests

## The `vt claude` Command Flow

When a user runs `vt claude`, the following sequence occurs:

### 1. Command Execution
```bash
vt claude "explain this code"
```

### 2. VT Wrapper Script (`web/bin/vt`)
The `vt` script:
- Detects if running on macOS and locates VibeTunnel app
- Finds the `vibetunnel` binary in app bundle or npm installation
- Executes: `vibetunnel fwd claude "explain this code"`

### 3. Vibetunnel Forward (fwd) Command
The `fwd` command:
- Creates a new terminal session via POST to `/api/sessions`
- Receives session ID from server
- Spawns the actual command (claude) in a PTY process
- Forwards PTY I/O through the VibeTunnel server

### 4. Session Creation
```http
POST http://localhost:4020/api/sessions
{
  "command": ["claude", "explain this code"],
  "cwd": "/current/working/directory",
  "cols": 80,
  "rows": 24
}
```

Response:
```json
{
  "sessionId": "a1b2c3d4-e5f6-g7h8-i9j0-k1l2m3n4o5p6",
  "createdAt": "2024-01-01T00:00:00Z"
}
```

### 5. Terminal Session Management
The server:
- Creates a PTY process for the command
- Manages terminal emulation via xterm.js
- Stores terminal buffer in memory
- Provides real-time access to buffer contents

## Buffer Snapshot API

The buffer API is crucial for VibeTunnelTalk to retrieve terminal content:

### Endpoint
```http
GET http://localhost:4020/api/sessions/{sessionId}/buffer
```

### Response Format
Binary encoded terminal buffer containing:
- Terminal dimensions (cols × rows)
- Cursor position (X, Y coordinates)
- Cell-by-cell terminal content with:
  - Character data
  - Foreground/background colors
  - Text attributes (bold, italic, etc.)

### Buffer Structure
```typescript
interface BufferSnapshot {
  cols: number;        // Terminal width
  rows: number;        // Terminal height
  viewportY: number;   // Viewport scroll position
  cursorX: number;     // Cursor X position
  cursorY: number;     // Cursor Y position
  cells: BufferCell[][]; // 2D array of terminal cells
}

interface BufferCell {
  char: string;        // Character(s) in cell
  fg?: number;         // Foreground color
  bg?: number;         // Background color
  attributes?: number; // Text attributes
}
```

### Polling Strategy
VibeTunnelTalk should:
1. Poll `/api/sessions/{sessionId}/buffer` every 500ms
2. Decode the binary buffer format
3. Extract plain text from cell grid
4. Detect changes between snapshots
5. Process only meaningful updates

## IPC Socket Protocol

For sending commands and receiving status updates:

### Socket Path
```
~/.vibetunnel/control/{session-id}/ipc.sock
```

### Message Format
```
+--------+--------+--------+--------+--------+----------------+
| Type   | Length                           | Payload        |
| 1 byte | 4 bytes (big-endian uint32)      | Length bytes   |
+--------+--------+--------+--------+--------+----------------+
```

### Message Types
- `0x01` STDIN_DATA: Send keyboard input
- `0x02` CONTROL_CMD: Resize, kill commands
- `0x03` STATUS_UPDATE: Claude activity status
- `0x04` HEARTBEAT: Keep-alive
- `0x05` ERROR: Error messages

### Sending Input Example
To send user input to the terminal:
1. Connect to IPC socket
2. Frame message: Type=0x01, Payload="user input\n"
3. Send over socket
4. Input appears in terminal

## Critical Integration Points for VibeTunnelTalk

### 1. Server Availability Check
Before attempting any operations:
```http
GET http://localhost:4020/api/health
```

Expected response:
```json
{
  "status": "healthy",
  "uptime": 3600,
  "version": "1.0.0",
  "sessions": 5
}
```

### 2. Session Discovery
To find active Claude sessions:
```http
GET http://localhost:4020/api/sessions
```

Response includes all active sessions with their IDs and metadata.

### 3. Buffer Polling Loop
```swift
// Pseudo-code for VibeTunnelTalk
while sessionActive {
    let buffer = fetchBuffer(sessionId)  // GET /api/sessions/{id}/buffer
    let text = extractText(buffer)
    let changes = detectChanges(previousText, text)
    if changes.meaningful {
        processWithOpenAI(changes)
    }
    sleep(500ms)
}
```

### 4. Voice Command Execution
To execute voice commands:
1. Connect to IPC socket at `~/.vibetunnel/control/{session-id}/ipc.sock`
2. Send STDIN_DATA messages with command text
3. Commands appear in terminal as if typed by user

## Important Operational Requirements

### Both Components Required
**CRITICAL**: Both the VibeTunnel macOS app AND a `vt claude` session must be running:

1. **VibeTunnel macOS App**: Provides the server infrastructure
   - Must be running (visible in menu bar)
   - Starts automatically on login (if configured)
   - Manages the HTTP server on port 4020

2. **Claude Session**: Created via `vt claude` command
   - Creates an active terminal session
   - Session ID required for buffer API access
   - Session remains active until Claude exits

### Startup Sequence for VibeTunnelTalk

1. **Verify VibeTunnel Server**:
   ```swift
   // Check if server is running
   GET http://localhost:4020/api/health
   ```

2. **Find or Create Claude Session**:
   ```swift
   // List existing sessions
   GET http://localhost:4020/api/sessions

   // If no Claude session exists, user must run:
   // $ vt claude
   ```

3. **Connect to Session**:
   ```swift
   // Start polling buffer
   GET http://localhost:4020/api/sessions/{sessionId}/buffer

   // Connect to IPC socket for commands
   connect("~/.vibetunnel/control/{sessionId}/ipc.sock")
   ```

## Session Lifecycle

### Session Creation
1. User runs `vt claude`
2. Server creates PTY process
3. Session ID generated
4. Terminal buffer initialized
5. IPC socket created at `~/.vibetunnel/control/{session-id}/ipc.sock`

### During Session
- Terminal output captured in memory buffer
- Buffer accessible via HTTP API
- Commands accepted via IPC socket
- Real-time status updates broadcast

### Session Termination
- Claude process exits
- PTY process cleaned up
- Buffer cleared from memory
- IPC socket removed
- Session removed from active list

## Error Conditions

### Server Not Running
- **Symptom**: Connection refused on port 4020
- **Solution**: Start VibeTunnel macOS app

### No Active Session
- **Symptom**: 404 on buffer API
- **Solution**: User must run `vt claude`

### Session Crashed
- **Symptom**: Session in list but buffer unavailable
- **Solution**: Create new session with `vt claude`

## Performance Considerations

### Buffer Polling
- **Recommended Rate**: 500ms intervals
- **Buffer Size**: Typically cols × rows cells
- **Network Load**: ~10-50KB per poll depending on content

### Change Detection
- Compare buffer snapshots to detect changes
- Filter out cursor movements and timestamps
- Focus on content changes relevant to narration

### IPC Socket
- **Message Size**: Keep under 64KB for best performance
- **Connection**: Maintain persistent connection
- **Reconnection**: Implement auto-reconnect on failure

## JWT Authentication for VibeTunnelTalk

Since VibeTunnelTalk is a separate application from VibeTunnel, it needs to authenticate properly to access the API endpoints. VibeTunnel uses JWT (JSON Web Token) authentication with macOS system credentials.

### Authentication Flow

#### 1. Login Endpoint
```http
POST http://localhost:4020/api/auth/login
Content-Type: application/json

{
  "username": "john",      // macOS username
  "password": "secret123"  // macOS password
}
```

**Response (Success)**:
```json
{
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "expiresIn": 86400,  // 24 hours in seconds
  "username": "john"
}
```

**Response (Failure)**:
```json
{
  "error": "Invalid credentials"
}
```

#### 2. Token Structure
The JWT token contains:
- **Header**: Algorithm and token type
- **Payload**:
  ```json
  {
    "username": "john",
    "iat": 1704067200,    // Issued at timestamp
    "exp": 1704153600     // Expiration timestamp (24 hours later)
  }
  ```
- **Signature**: HMAC SHA256 signature

#### 3. Using the Token
Once you have the JWT token, include it in all API requests:

```http
GET http://localhost:4020/api/sessions/{sessionId}/buffer
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

### Authentication Implementation Details

#### Password Verification
VibeTunnel uses macOS's native authentication system:
- Verifies against the actual macOS user account
- Uses PAM (Pluggable Authentication Modules) on macOS
- The username/password are the same credentials used to log into the Mac

#### Token Management
- **Expiration**: Tokens expire after 24 hours
- **Storage**: Store the token securely in VibeTunnelTalk (Keychain recommended)
- **Renewal**: Get a new token before expiration by logging in again
- **Validation**: Server validates token signature and expiration on each request

### Implementation Steps for VibeTunnelTalk

#### 1. Initial Setup Check
```swift
// Check if authentication is required
func checkAuthenticationRequired() async -> Bool {
    let url = URL(string: "http://localhost:4020/api/auth/config")!
    let (data, _) = try? await URLSession.shared.data(from: url)

    if let data = data,
       let config = try? JSONDecoder().decode(AuthConfig.self, from: data) {
        return !config.noAuth  // Authentication required if noAuth is false
    }
    return true  // Assume auth required if can't check
}

struct AuthConfig: Codable {
    let noAuth: Bool
    let enableSSHKeys: Bool
    let disallowUserPassword: bool
}
```

#### 2. Login Flow
```swift
struct LoginRequest: Codable {
    let username: String
    let password: String
}

struct LoginResponse: Codable {
    let token: String
    let expiresIn: Int
    let username: String
}

func authenticate(username: String, password: String) async throws -> String {
    let url = URL(string: "http://localhost:4020/api/auth/login")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body = LoginRequest(username: username, password: password)
    request.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse,
          httpResponse.statusCode == 200 else {
        throw AuthError.invalidCredentials
    }

    let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)

    // Store token securely (e.g., in Keychain)
    storeToken(loginResponse.token)

    return loginResponse.token
}
```

#### 3. Using Token for API Calls
```swift
func fetchBuffer(sessionId: String, token: String) async throws -> Data {
    let url = URL(string: "http://localhost:4020/api/sessions/\(sessionId)/buffer")!
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw NetworkError.invalidResponse
    }

    switch httpResponse.statusCode {
    case 200:
        return data
    case 401:
        // Token expired or invalid - need to re-authenticate
        throw AuthError.tokenExpired
    case 404:
        throw SessionError.notFound
    default:
        throw NetworkError.unexpectedStatus(httpResponse.statusCode)
    }
}
```

### User Interface Considerations

VibeTunnelTalk will need:

1. **Login View**:
   - Username field (pre-fill with `NSUserName()` for current macOS user)
   - Password field (secure text entry)
   - "Remember me" option (store token in Keychain)

2. **Token Storage**:
   - Store in macOS Keychain for security
   - Include expiration time to know when to refresh

3. **Auto-refresh Logic**:
   - Check token expiration before API calls
   - Prompt for re-authentication when expired
   - Consider showing auth status in UI

### Error Handling

Common authentication errors to handle:

| Error | HTTP Status | Meaning | User Action |
|-------|------------|---------|-------------|
| Invalid credentials | 401 | Wrong username/password | Re-enter credentials |
| Token expired | 401 | JWT token expired | Log in again |
| No auth required | N/A | Server running with --no-auth | Skip login |
| Server unavailable | Connection error | VibeTunnel not running | Start VibeTunnel |

### Security Notes

1. **Never store passwords** - only store the JWT token
2. **Use Keychain** for secure token storage
3. **Handle token expiration** gracefully
4. **Clear tokens** on app logout or uninstall
5. **Use HTTPS** if VibeTunnel is configured for network access (not localhost)

### Testing Authentication

To test without real credentials during development:

1. **Check if no-auth mode**:
   ```bash
   curl http://localhost:4020/api/auth/config
   ```

2. **Test login**:
   ```bash
   curl -X POST http://localhost:4020/api/auth/login \
     -H "Content-Type: application/json" \
     -d '{"username":"yourusername","password":"yourpassword"}'
   ```

3. **Test authenticated request**:
   ```bash
   curl http://localhost:4020/api/sessions \
     -H "Authorization: Bearer YOUR_JWT_TOKEN"
   ```

## Summary

VibeTunnelTalk integration requires:

1. **Running VibeTunnel macOS app** (provides server on port 4020)
2. **JWT Authentication** (login with macOS credentials, use token for API calls)
3. **Active Claude session** (created via `vt claude`)
4. **Buffer polling** (500ms intervals via HTTP API with Bearer token)
5. **IPC socket connection** (for sending commands)
6. **Change detection** (intelligent filtering of buffer updates)

The architecture is designed for real-time terminal monitoring with minimal latency, providing complete access to terminal content and the ability to inject commands as needed for voice interaction.