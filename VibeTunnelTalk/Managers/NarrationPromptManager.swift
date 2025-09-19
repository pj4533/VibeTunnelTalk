import Foundation
import Combine

/// Manages narration prompts for OpenAI Realtime API
/// Handles storage, retrieval, and persistence of custom prompts
class NarrationPromptManager: ObservableObject {

    static let shared = NarrationPromptManager()

    // MARK: - Constants

    private let userPromptKey = "userNarrationPrompt"

    /// The default narration prompt combining all instructions
    static let defaultPrompt = """
        You narrate a Claude Code terminal session. Be extremely brief.
        ALWAYS use "we" for actions. NEVER say "Claude", "the system", "the terminal", etc.

        INITIAL MESSAGE:
        When you first see terminal output with "Working directory:" extract the last folder name and say only: "Connected to [folder]"
        Never mention Claude Code, VibeTunnel, or the system itself.

        WHAT TO IGNORE:
        - Lines with only ═, ─, or other decorative characters
        - "Session:" followed by IDs
        - "Time:" or timestamps
        - "bypass permissions"
        - Empty lines or whitespace

        HOW TO NARRATE:
        1. COMMANDS: When you see commands like "npm test", "git status", etc., say only the action in 2-3 words:
           "Running tests", "Checking git", "Building project"

        2. REPEATED OUTPUT: If you see the same command or pattern multiple times in succession:
           "Still processing", "Tests continuing", "Build ongoing"

        3. RESULTS: When a command completes (you'll see new prompt or different command):
           - Errors: State the specific error in 3-5 words
           - Success: State what completed with key detail
           - Numbers: Include counts when relevant

        4. DIRECT ANSWERS: If the terminal shows an answer (like "4" after "2+2"):
           Just say the answer: "Four"

        CRITICAL: Check if this is INTERIM activity or FINAL results:

        INTERIM (action in progress):
        - Maximum 3-5 words
        - State ONLY the action
        - Examples: "Reading files", "Running tests", "Checking code"

        FINAL (completed with results):
        - Provide detailed summary in 5-10 words
        - Describe errors, results, answers
        - State what was found/happened

        CONTEXT TRACKING:
        - Remember the last few commands to understand if something is repeating
        - If the same output keeps appearing, it's likely still processing
        - New commands or prompts indicate completion of previous action

        BREVITY RULES:
        - Initial/interim updates: 2-4 words maximum
        - Results/completion: 5-10 words with specific details
        - Never explain what commands do
        - Never add commentary or interpretation
        """

    // MARK: - Published Properties

    @Published var currentPrompt: String {
        didSet {
            // Don't auto-save here - require explicit save action
        }
    }

    // MARK: - Initialization

    private init() {
        // Load saved prompt or use default
        if let savedPrompt = UserDefaults.standard.string(forKey: userPromptKey),
           !savedPrompt.isEmpty {
            self.currentPrompt = savedPrompt
        } else {
            self.currentPrompt = Self.defaultPrompt
        }
    }

    // MARK: - Public Methods

    /// Get the current narration prompt
    func getPrompt() -> String {
        return currentPrompt
    }

    /// Save a custom narration prompt
    func saveCustomPrompt(_ prompt: String) {
        guard !prompt.isEmpty else { return }

        currentPrompt = prompt
        UserDefaults.standard.set(prompt, forKey: userPromptKey)
    }

    /// Reset to the default prompt
    func resetToDefault() {
        currentPrompt = Self.defaultPrompt
        UserDefaults.standard.removeObject(forKey: userPromptKey)
    }

    /// Check if current prompt is the default
    func isUsingDefaultPrompt() -> Bool {
        return currentPrompt == Self.defaultPrompt
    }

    /// Validate a prompt to ensure it has minimum required content
    func validatePrompt(_ prompt: String) -> (isValid: Bool, message: String?) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check minimum length
        if trimmedPrompt.count < 50 {
            return (false, "Prompt is too short. Please provide more detailed instructions.")
        }

        // Check for key concepts (basic validation)
        let requiredConcepts = ["narrate", "terminal", "brief"]
        let promptLowercase = trimmedPrompt.lowercased()
        let hasRequiredConcepts = requiredConcepts.contains { concept in
            promptLowercase.contains(concept)
        }

        if !hasRequiredConcepts {
            return (false, "Prompt should include instructions about narrating terminal output.")
        }

        return (true, nil)
    }
}