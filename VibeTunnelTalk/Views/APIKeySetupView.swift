//
//  APIKeySetupView.swift
//  VibeTunnelTalk
//
//  Created by PJ Gray on 9/12/25.
//

import SwiftUI

struct APIKeySetupView: View {
    let onSave: () -> Void
    @State private var apiKeyText = ""
    @State private var showingSaveError = false

    var body: some View {
        VStack(spacing: 20) {
            Text("OpenAI API Key Required")
                .font(.headline)

            Text("Please enter your OpenAI API key to continue")
                .font(.subheadline)
                .foregroundColor(.secondary)

            SecureField("API Key", text: $apiKeyText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 400)

            if showingSaveError {
                Text("Failed to save API key to Keychain")
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button("Save") {
                if KeychainHelper.saveAPIKey(apiKeyText) {
                    onSave()
                } else {
                    showingSaveError = true
                }
            }
            .disabled(apiKeyText.isEmpty)
            .keyboardShortcut(.return)
        }
        .padding(30)
    }
}