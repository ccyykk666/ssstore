//
//  LogView.swift
//  Asspp
//
//  Created on 2026/2/20.
//

import SwiftUI

struct LogView: View {
    @State private var messages: [String] = []

    private func fill() {
        messages = LogManager.shared.getMessages()
    }

    var body: some View {
        List {
            ForEach(Array(messages.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(nil)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .listStyle(.plain)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { fill() }) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear { fill() }
        .navigationTitle("Logs")
    }
}


