import SwiftUI

struct SettingsView: View {
    @Binding var debugOutputEnabled: Bool
    @AppStorage("useSmartProcessing") private var useSmartProcessing = true
    @AppStorage("sampleInterval") private var sampleInterval = 1.0
    @AppStorage("minChangeThreshold") private var minChangeThreshold = 10.0
    @AppStorage("maxChunkSize") private var maxChunkSize = 500.0

    @State private var apiKey: String = ""
    @State private var showAPIKeySaved = false

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
                    if let window = NSApplication.shared.keyWindow {
                        window.close()
                    }
                }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // API Key Section
                    GroupBox(label: Label("OpenAI API", systemImage: "key.fill")) {
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

                    // Debug Section
                    GroupBox(label: Label("Debug Options", systemImage: "ladybug")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Enable Debug Output", isOn: $debugOutputEnabled)
                                .help("Save raw terminal output to debug files")

                            Text("Debug files are saved to ~/Library/Logs/VibeTunnelTalk/")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Button("Open Logs Folder") {
                                openLogsFolder()
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

                                // These would be populated from the actual processor
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
                .padding()
            }
        }
        .frame(width: 500, height: 600)
        .onAppear {
            loadExistingAPIKey()
        }
    }

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

    private func openLogsFolder() {
        let logsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VibeTunnelTalk")

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: logsPath, withIntermediateDirectories: true)

        NSWorkspace.shared.open(logsPath)
    }
}