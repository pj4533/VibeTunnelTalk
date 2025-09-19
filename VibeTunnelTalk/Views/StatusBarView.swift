//
//  StatusBarView.swift
//  VibeTunnelTalk
//
//  Created by PJ Gray on 9/12/25.
//

import SwiftUI

struct StatusBarView: View {
    let socketConnected: Bool
    let openAIConnected: Bool
    let isProcessing: Bool

    var body: some View {
        HStack {
            // Connection Status
            HStack(spacing: 15) {
                StatusIndicator(
                    label: "VibeTunnel",
                    isConnected: socketConnected
                )

                StatusIndicator(
                    label: "OpenAI",
                    isConnected: openAIConnected
                )
            }

            Spacer()

            // Processing Status
            if isProcessing {
                HStack(spacing: 5) {
                    ProgressView()
                        .scaleEffect(0.5)
                    Text("Processing")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Ready")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.1))
    }
}

struct StatusIndicator: View {
    let label: String
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 6, height: 6)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}