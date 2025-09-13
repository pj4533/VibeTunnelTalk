import Foundation
import Combine
import OSLog

class VoiceCommandProcessor: ObservableObject {
    private let logger = AppLogger.voiceCommands
    
    @Published var lastCommand: String = ""
    @Published var isProcessing = false
    
    /// Process a function call from OpenAI
    func processFunctionCall(_ functionCall: FunctionCall, completion: @escaping (String) -> Void) {
        logger.info("Processing function call: \(functionCall.name)")
        
        switch functionCall.name {
        case "execute_terminal_command":
            if let command = functionCall.parameters["command"] as? String {
                logger.info("Executing terminal command: \(command)")
                lastCommand = command
                
                // Add newline if not present
                let finalCommand = command.hasSuffix("\n") ? command : "\(command)\n"
                completion(finalCommand)
            }
            
        case "control_session":
            if let action = functionCall.parameters["action"] as? String {
                handleSessionControl(action: action, completion: completion)
            }
            
        default:
            logger.warning("Unknown function call: \(functionCall.name)")
        }
    }
    
    /// Map natural language to terminal commands
    func interpretVoiceCommand(_ text: String) -> String? {
        let lowercased = text.lowercased()
        
        // Common command mappings
        if lowercased.contains("list") && lowercased.contains("file") {
            return "ls -la"
        }
        
        if lowercased.contains("show") && lowercased.contains("directory") {
            return "pwd"
        }
        
        if lowercased.contains("run") && lowercased.contains("test") {
            return "npm test"
        }
        
        if lowercased.contains("build") && lowercased.contains("project") {
            return "npm run build"
        }
        
        if lowercased.contains("install") && lowercased.contains("dependencies") {
            return "npm install"
        }
        
        if lowercased.contains("git") && lowercased.contains("status") {
            return "git status"
        }
        
        if lowercased.contains("clear") && (lowercased.contains("terminal") || lowercased.contains("screen")) {
            return "clear"
        }
        
        // If no specific mapping, return nil
        return nil
    }
    
    // MARK: - Private Methods
    
    private func handleSessionControl(action: String, completion: @escaping (String) -> Void) {
        switch action {
        case "pause":
            // Send Ctrl+Z to pause current process
            completion("\u{001A}") // ASCII for Ctrl+Z
            
        case "resume":
            // Send 'fg' command to resume
            completion("fg\n")
            
        case "stop":
            // Send Ctrl+C to stop current process
            completion("\u{0003}") // ASCII for Ctrl+C
            
        case "restart":
            // Stop and restart (send Ctrl+C then repeat last command)
            completion("\u{0003}") // ASCII for Ctrl+C
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion("!!\n") // Repeat last command
            }
            
        default:
            logger.warning("Unknown session control action: \(action)")
        }
    }
}