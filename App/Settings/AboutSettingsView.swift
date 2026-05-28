// App/Settings/AboutSettingsView.swift
import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Mumblur").font(.largeTitle)
            Text("Local push-to-talk dictation. On-device only.")
            Divider()
            Text("How tuning works").font(.headline)
            Text("Mumblur tunes the prompt biasing and post-transcription rules per profile. It does not retrain the model weights. Calibration reports improvement on a held-out evaluation set.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
