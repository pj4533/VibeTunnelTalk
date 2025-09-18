import Foundation
import OSLog
import Network

// MARK: - Session Discovery
extension VibeTunnelSocketManager {

    /// Find available VibeTunnel sessions
    func findAvailableSessions() -> [String] {
        // Now that we're not sandboxed, this returns the real home directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let controlPath = homeDir + "/.vibetunnel/control"
        let fm = FileManager.default

        // Silently discover sessions

        // Check if .vibetunnel directory exists
        let vibetunnelPath = homeDir + "/.vibetunnel"
        if !fm.fileExists(atPath: vibetunnelPath) {
            logger.verbose(".vibetunnel directory does not exist at: \(vibetunnelPath)")
            return []
        }
        // Found .vibetunnel directory

        // Check if control directory exists
        if !fm.fileExists(atPath: controlPath) {
            logger.verbose("Control directory does not exist at: \(controlPath)")

            // List what's in .vibetunnel directory for debugging
            if let vibetunnelContents = try? fm.contentsOfDirectory(atPath: vibetunnelPath) {
                logger.verbose("Contents of .vibetunnel: \(vibetunnelContents.joined(separator: ", "))")
            }
            return []
        }
        // Found control directory

        // Get contents of control directory
        guard let contents = try? fm.contentsOfDirectory(atPath: controlPath) else {
            logger.warning("Failed to read contents of control directory at: \(controlPath)")
            return []
        }

        // Found items in control directory

        // Filter for directories that contain an ipc.sock file
        let validSessions = contents.filter { sessionId in
            let sessionPath = "\(controlPath)/\(sessionId)"
            let socketPath = "\(sessionPath)/ipc.sock"

            // Check if it's a directory
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: sessionPath, isDirectory: &isDirectory)

            if !exists || !isDirectory.boolValue {
                // Not a directory
                return false
            }

            // Check for ipc.sock file and validate it's active
            let hasSocket = fm.fileExists(atPath: socketPath)
            if hasSocket {
                // Try to connect to verify it's a live socket
                if isSocketActive(at: socketPath) {
                    // Found valid active session
                    return true
                } else {
                    // Socket file exists but is stale
                    logger.verbose("Socket file exists but is stale: \(sessionId)")
                    return false
                }
            } else {
                // No socket file
                return false
            }
        }

        if validSessions.isEmpty {
            logger.debug("No active sessions found")
        } else {
            logger.info("🔍 Found \(validSessions.count) active session(s)")
        }

        return validSessions
    }

    /// Check if a Unix domain socket is active by attempting to connect
    private func isSocketActive(at path: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var isActive = false

        let endpoint = NWEndpoint.unix(path: path)
        let connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Successfully connected - socket is active
                isActive = true
                connection.cancel()
                semaphore.signal()
            case .failed:
                // Failed to connect - socket is stale
                isActive = false
                semaphore.signal()
            case .cancelled:
                semaphore.signal()
            default:
                break
            }
        }

        // Start connection attempt
        let testQueue = DispatchQueue(label: "socket.test")
        connection.start(queue: testQueue)

        // Wait up to 1 second for connection result
        _ = semaphore.wait(timeout: .now() + 1.0)

        // Clean up
        connection.cancel()

        return isActive
    }
}