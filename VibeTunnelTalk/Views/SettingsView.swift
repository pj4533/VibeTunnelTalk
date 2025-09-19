import SwiftUI

struct SettingsView: View {
    @AppStorage("useSmartProcessing") private var useSmartProcessing = true
    @AppStorage("sampleInterval") private var sampleInterval = 1.0
    @AppStorage("minChangeThreshold") private var minChangeThreshold = 10.0
    @AppStorage("maxChunkSize") private var maxChunkSize = 500.0

    @State private var apiKey: String = ""
    @State private var showAPIKeySaved = false
    @State private var selectedTab = "general"
    @State private var editingPrompt: String = ""
    @State private var showPromptSaved = false
    @State private var showPromptValidationError = false
    @State private var promptValidationMessage = ""
    @StateObject private var debugSettings = DebugSettings.shared
    @StateObject private var promptManager = NarrationPromptManager.shared
    @Environment(\.dismiss) private var dismiss

    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Title Bar
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") {
                    onSave()
                    dismiss()
                }
            }
            .padding()

            Divider()

            // Tab Selection
            HStack(spacing: 0) {
                TabButton(title: "General", icon: "gearshape", isSelected: selectedTab == "general") {
                    selectedTab = "general"
                }
                TabButton(title: "OpenAI", icon: "brain", isSelected: selectedTab == "openai") {
                    selectedTab = "openai"
                }
                TabButton(title: "Advanced", icon: "ladybug", isSelected: selectedTab == "advanced") {
                    selectedTab = "advanced"
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Divider()

            // Tab Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case "general":
                        generalTab
                    case "openai":
                        openAITab
                    case "advanced":
                        advancedTab
                    default:
                        EmptyView()
                    }
                }
                .padding()
            }
        }
        .frame(width: 550, height: 650)
        .onAppear {
            loadExistingAPIKey()
            editingPrompt = promptManager.currentPrompt
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Smart Processing Section
            GroupBox(label: Label("Smart Terminal Processing", systemImage: "brain")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable Smart Processing", isOn: $useSmartProcessing)
                        .help("Use intelligent terminal buffer reconstruction and filtering")

                    Text("Smart processing dramatically reduces data sent to OpenAI by reconstructing the terminal state and only sending meaningful changes.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if useSmartProcessing {
                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            // Sample Interval
                            HStack {
                                Text("Sample Interval:")
                                Slider(value: $sampleInterval, in: 0.5...5.0, step: 0.5)
                                Text("\(String(format: "%.1f", sampleInterval))s")
                                    .frame(width: 40)
                            }
                            .help("How often to sample the terminal buffer for changes")

                            // Min Change Threshold
                            HStack {
                                Text("Min Change Size:")
                                Slider(value: $minChangeThreshold, in: 5...50, step: 5)
                                Text("\(Int(minChangeThreshold)) chars")
                                    .frame(width: 60)
                            }
                            .help("Minimum characters changed to trigger an update")

                            // Max Chunk Size
                            HStack {
                                Text("Max Chunk Size:")
                                Slider(value: $maxChunkSize, in: 100...1000, step: 50)
                                Text("\(Int(maxChunkSize)) chars")
                                    .frame(width: 60)
                            }
                            .help("Maximum characters to send in one update")
                        }
                        .font(.system(size: 11))
                    }
                }
            }

            // Performance Metrics (if connected)
            if useSmartProcessing {
                GroupBox(label: Label("Performance Metrics", systemImage: "chart.line.uptrend.xyaxis")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Metrics will appear here when connected to a session")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            Label("Data Reduction:", systemImage: "arrow.down.circle")
                            Spacer()
                            Text("--")
                        }
                        .font(.system(size: 11))

                        HStack {
                            Label("Updates Sent:", systemImage: "paperplane")
                            Spacer()
                            Text("--")
                        }
                        .font(.system(size: 11))

                        HStack {
                            Label("Events Processed:", systemImage: "cpu")
                            Spacer()
                            Text("--")
                        }
                        .font(.system(size: 11))
                    }
                }
            }
        }
    }

    // MARK: - OpenAI Tab

    private var openAITab: some View {
        VStack(alignment: .leading, spacing: 20) {
            // API Key Section
            GroupBox(label: Label("API Configuration", systemImage: "key.fill")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Enter your OpenAI API key for Realtime API access")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        SecureField("sk-...", text: $apiKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())

                        Button("Save") {
                            saveAPIKey()
                        }
                        .disabled(apiKey.isEmpty)
                    }

                    if showAPIKeySaved {
                        Label("API key saved securely", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }

            // Narration Prompt Section
            GroupBox(label: Label("Narration Prompt", systemImage: "text.quote")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Customize how the AI narrates your terminal sessions")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Prompt Editor
                    VStack(alignment: .leading, spacing: 8) {
                        Text("System Prompt:")
                            .font(.system(size: 11, weight: .medium))

                        TextEditor(text: $editingPrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(minHeight: 200, maxHeight: 300)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                    }

                    // Action Buttons
                    HStack {
                        Button("Reset to Default") {
                            resetPromptToDefault()
                        }
                        .foregroundColor(.orange)

                        Spacer()

                        Button("Save Prompt") {
                            savePrompt()
                        }
                        .disabled(editingPrompt == promptManager.currentPrompt)
                    }

                    // Feedback Messages
                    if showPromptSaved {
                        Label("Prompt saved successfully", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }

                    if showPromptValidationError {
                        Label(promptValidationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    // Help Text
                    Text("Tip: Your prompt should instruct the AI to be brief and focus on important terminal events.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .italic()
                }
            }
        }
    }

    // MARK: - Advanced Tab

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Debug Section
            GroupBox(label: Label("Debug Options", systemImage: "ladybug")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("OpenAI updates are logged to ~/Library/Logs/VibeTunnelTalk/")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Divider()

                    Toggle("Log raw terminal output (with ANSI codes)", isOn: $debugSettings.logRawTerminalOutput)
                        .help("When enabled, logs raw terminal output with all ANSI escape codes instead of cleaned output")

                    Toggle("Verbose logging", isOn: $debugSettings.verboseLogging)
                        .help("Enable verbose debug logging in console")

                    Toggle("Save debug files", isOn: $debugSettings.saveDebugFiles)
                        .help("Save detailed debug logs to disk")

                    Divider()

                    HStack {
                        Button("Open Logs Folder") {
                            openLogsFolder()
                        }

                        Spacer()

                        Button("Reset Debug Settings") {
                            debugSettings.resetToDefaults()
                        }
                        .foregroundColor(.orange)
                    }
                }
            }
        }
    }

    // MARK: - Helper Methods

    private func saveAPIKey() {
        guard !apiKey.isEmpty else { return }

        if KeychainHelper.saveAPIKey(apiKey) {
            showAPIKeySaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showAPIKeySaved = false
            }
        }
    }

    private func loadExistingAPIKey() {
        if let existingKey = KeychainHelper.loadAPIKey() {
            apiKey = existingKey
        }
    }

    private func savePrompt() {
        // Validate the prompt
        let validation = promptManager.validatePrompt(editingPrompt)

        if !validation.isValid {
            showPromptValidationError = true
            promptValidationMessage = validation.message ?? "Invalid prompt"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                showPromptValidationError = false
            }
            return
        }

        // Save the prompt
        promptManager.saveCustomPrompt(editingPrompt)
        showPromptSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showPromptSaved = false
        }
    }

    private func resetPromptToDefault() {
        promptManager.resetToDefault()
        editingPrompt = promptManager.currentPrompt
        showPromptSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showPromptSaved = false
        }
    }

    private func openLogsFolder() {
        let logsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VibeTunnelTalk")

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: logsPath, withIntermediateDirectories: true)

        NSWorkspace.shared.open(logsPath)
    }
}

// MARK: - Tab Button Component

struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}