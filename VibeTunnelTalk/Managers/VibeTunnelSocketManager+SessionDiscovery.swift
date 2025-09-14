import Foundation
import OSLog

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
            logger.error("[VIBETUNNEL-DISCOVERY] ❌ .vibetunnel directory does not exist at: \(vibetunnelPath)")
            return []
        }
        // Found .vibetunnel directory

        // Check if control directory exists
        if !fm.fileExists(atPath: controlPath) {
            logger.error("[VIBETUNNEL-DISCOVERY] ❌ Control directory does not exist at: \(controlPath)")

            // List what's in .vibetunnel directory for debugging
            if let vibetunnelContents = try? fm.contentsOfDirectory(atPath: vibetunnelPath) {
                logger.debug("[VIBETUNNEL-DISCOVERY] Contents of .vibetunnel: \(vibetunnelContents.joined(separator: ", "))")
            }
            return []
        }
        // Found control directory

        // Get contents of control directory
        guard let contents = try? fm.contentsOfDirectory(atPath: controlPath) else {
            logger.error("[VIBETUNNEL-DISCOVERY] ❌ Failed to read contents of control directory at: \(controlPath)")
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

            // Check for ipc.sock file
            let hasSocket = fm.fileExists(atPath: socketPath)
            if hasSocket {
                // Found valid session
            } else {
                // No socket file
            }

            return hasSocket
        }

        if validSessions.isEmpty {
            logger.warning("[VIBETUNNEL] No active sessions found")
        } else {
            logger.info("[VIBETUNNEL] Found \(validSessions.count) active session(s)")
        }

        return validSessions
    }
}