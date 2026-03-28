import SwiftUI

struct MenuBarPopoverView: View {
    let coordinator: AppCoordinator
    let settings: AppSettings
    let onShowMainWindow: () -> Void
    let onCheckForUpdates: () -> Void
    let onQuit: () -> Void

    @State private var elapsedSeconds: Int = 0
    @State private var timerTask: Task<Void, Never>?

    private var recordingStartedAt: Date? {
        if case .recording(let metadata) = coordinator.state {
            return metadata.startedAt
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusLine
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            Button(action: onShowMainWindow) {
                HStack {
                    Text("Show Lore")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Button(action: onCheckForUpdates) {
                HStack {
                    Text("Check for Updates…")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            Button(action: onQuit) {
                HStack {
                    Text("Quit Lore")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .padding(.bottom, 4)
        }
        .frame(width: 280)
        .onAppear {
            if coordinator.isRecording {
                startTimer()
            }
        }
        .onDisappear {
            stopTimer()
        }
        .onChange(of: coordinator.isRecording) { _, recording in
            if recording {
                startTimer()
            } else {
                stopTimer()
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green.opacity(0.7))
                .frame(width: 8, height: 8)
            Text("Dictation ready")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // Meeting mode primary action — hidden until meeting mode is ready
    // @ViewBuilder
    // private var primaryAction: some View {
    //     if coordinator.isRecording {
    //         Button(action: { coordinator.handle(.userStopped, settings: settings) }) {
    //             Text("Stop Recording").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity)
    //         }.buttonStyle(.borderedProminent).tint(.red).controlSize(.regular)
    //     } else {
    //         Button(action: {
    //             guard settings.hasAcknowledgedRecordingConsent else { onShowMainWindow(); return }
    //             coordinator.handle(.userStarted(.manual()), settings: settings)
    //         }) {
    //             Text("Start Recording").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity)
    //         }.buttonStyle(.borderedProminent).controlSize(.regular)
    //     }
    // }
    @ViewBuilder
    private var primaryAction: some View {
        EmptyView()
    }

    private var formattedTime: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func startTimer() {
        updateElapsed()
        stopTimer()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                updateElapsed()
            }
        }
    }

    private func updateElapsed() {
        if let start = recordingStartedAt {
            elapsedSeconds = max(0, Int(Date().timeIntervalSince(start)))
        } else {
            elapsedSeconds = 0
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        elapsedSeconds = 0
    }
}
