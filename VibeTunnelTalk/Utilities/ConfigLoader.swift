import Foundation

class ConfigLoader {
    static func loadAPIKey() -> String? {
        // First try to load from .env file
        if let envKey = loadFromEnvFile() {
            return envKey
        }
        
        // Fallback to environment variable
        return ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }
    
    private static func loadFromEnvFile() -> String? {
        let projectPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        
        let envPath = projectPath.appendingPathComponent(".env")
        
        guard let envContent = try? String(contentsOf: envPath, encoding: .utf8) else {
            return nil
        }
        
        // Parse .env file
        let lines = envContent.components(separatedBy: .newlines)
        for line in lines {
            let parts = line.components(separatedBy: "=")
            if parts.count == 2 && parts[0] == "OPENAI_API_KEY" {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        return nil
    }
}