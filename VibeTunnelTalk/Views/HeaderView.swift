//
//  HeaderView.swift
//  VibeTunnelTalk
//
//  Created by PJ Gray on 9/12/25.
//

import SwiftUI

struct HeaderView: View {
    let isConnected: Bool
    @Binding var showSettings: Bool

    var body: some View {
        HStack {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundColor(isConnected ? .green : .gray)

            Text("VibeTunnelTalk")
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            Button(action: { showSettings = true }) {
                Image(systemName: "gear")
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
}