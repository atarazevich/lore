import AppKit
import SwiftUI

/// "Report a problem" (#84, design §7): a free-text field, an honest manifest of
/// what is and isn't attached, and a two-tab preview — *What this means* (the
/// snapshot in plain sentences) and *Raw data* (the exact bytes to be sent). The
/// diagnostic payload is mandatory, not a toggle: the checkmarks state facts.
/// Dark-only, XMOTheme tokens (D-031). Presented as a sheet from the health
/// panel and from Settings.
struct ProblemReportView: View {
    let healthMonitor: HealthMonitor
    var uploader = ReportUploader()
    var onClose: () -> Void

    @State private var message = ""
    @State private var showPreview = false
    @State private var phase: Phase = .editing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase: Equatable {
        case editing
        case sending
        case sent(id: String)
        case failed(message: String)
    }

    /// The manifest, stated once (design §7). These are the checkmarks the
    /// preview then proves with the real bytes.
    private static let attached = [
        "Health snapshot (which checks pass or fail)",
        "Diagnostic events — the last few hundred typed records",
        "Mac model, macOS version, app version and build",
    ]
    private static let notAttached = [
        "No transcripts, recordings, or file names",
        "No device names, account, or keys",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            XMODivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    prompt
                    manifest
                    footerStatus
                }
                .padding(20)
            }
            XMODivider()
            actions
        }
        .frame(width: 460, height: 560)
        .background(XMOTheme.Surface.window)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPreview) {
            ProblemReportPreview(report: buildReport(), onClose: { showPreview = false })
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Report a problem")
                    .font(XMOTheme.Typography.control)
                    .foregroundStyle(XMOTheme.TextColor.primary)
                Text("Sends a diagnostic report so we can see what your Mac saw.")
                    .font(XMOTheme.Typography.meta)
                    .foregroundStyle(XMOTheme.TextColor.muted)
            }
            Spacer()
            XMOIconButton(systemName: "xmark", label: "Close report", action: onClose)
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
    }

    // MARK: - Prompt

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            XMOSectionLabel(text: "What happened?")
            ZStack(alignment: .topLeading) {
                if message.isEmpty {
                    Text("Describe what went wrong — e.g. the Fn key stopped inserting text after a meeting.")
                        .font(XMOTheme.Typography.body)
                        .foregroundStyle(XMOTheme.TextColor.faint)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $message)
                    .font(XMOTheme.Typography.body)
                    .foregroundStyle(XMOTheme.TextColor.primary)
                    .scrollContentBackground(.hidden)
                    .frame(height: 96)
                    .padding(4)
            }
            .background(XMOTheme.Surface.card3, in: RoundedRectangle(cornerRadius: XMOTheme.Radius.chip))
            .disabled(isSending)
        }
    }

    // MARK: - Manifest

    private var manifest: some View {
        VStack(alignment: .leading, spacing: 8) {
            XMOSectionLabel(text: "What gets sent")
            XMOCard {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Self.attached, id: \.self) { manifestRow(icon: "checkmark", color: XMOTheme.Accent.green, text: $0) }
                    ForEach(Self.notAttached, id: \.self) { manifestRow(icon: "xmark", color: XMOTheme.TextColor.muted, text: $0) }
                }
                .padding(12)
            }
            Button {
                showPreview = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                    Text("Preview exactly what's sent")
                }
                .font(XMOTheme.Typography.meta)
                .foregroundStyle(XMOTheme.Accent.blue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview the report contents")
        }
    }

    private func manifestRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(text)
                .font(XMOTheme.Typography.meta)
                .foregroundStyle(XMOTheme.TextColor.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Status (sent / failed)

    @ViewBuilder
    private var footerStatus: some View {
        switch phase {
        case .sent(let id):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(XMOTheme.Accent.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Report \(id) sent")
                        .font(XMOTheme.Typography.control)
                        .foregroundStyle(XMOTheme.TextColor.primary)
                    Text("Quote this ID to us and we'll find it.")
                        .font(XMOTheme.Typography.meta)
                        .foregroundStyle(XMOTheme.TextColor.muted)
                }
                Spacer(minLength: 0)
                XMOCopyButton(label: "Copy report ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(id, forType: .string)
                }
            }
            .padding(12)
            .background(XMOTheme.Surface.card2, in: RoundedRectangle(cornerRadius: XMOTheme.Radius.card))
        case .failed(let error):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(XMOTheme.Accent.amber)
                Text(error)
                    .font(XMOTheme.Typography.meta)
                    .foregroundStyle(XMOTheme.TextColor.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(XMOTheme.Surface.card2, in: RoundedRectangle(cornerRadius: XMOTheme.Radius.card))
        case .editing, .sending:
            EmptyView()
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer()
            if case .sent = phase {
                Button("Done", action: onClose)
                    .buttonStyle(ProblemReportButtonStyle(filled: true))
            } else {
                Button("Cancel", action: onClose)
                    .buttonStyle(ProblemReportButtonStyle(filled: false))
                    .disabled(isSending)
                Button(sendLabel) { send() }
                    .buttonStyle(ProblemReportButtonStyle(filled: true))
                    .disabled(!canSend)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
    }

    private var sendLabel: String {
        switch phase {
        case .sending: return "Sending…"
        case .failed: return "Try again"
        default: return "Send report"
        }
    }

    private var isSending: Bool { phase == .sending }

    private var canSend: Bool {
        !isSending && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Build & send

    /// A fresh report: re-probe the cheap chain, then serialize the current
    /// message with that snapshot and the recent events. This is the same value
    /// the preview renders and the uploader posts.
    private func buildReport() -> ProblemReport {
        healthMonitor.refresh()
        return ProblemReport.build(
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            health: healthMonitor.snapshot
        )
    }

    private func send() {
        let report = buildReport()
        phase = .sending
        Task {
            do {
                let id = try await uploader.upload(report)
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { phase = .sent(id: id) }
            } catch let error as ReportUploader.UploadError {
                phase = .failed(message: error.errorDescription ?? "Couldn't send the report. Please try again.")
            } catch {
                phase = .failed(message: "Couldn't send the report. Please try again.")
            }
        }
    }
}

// MARK: - Preview sheet (two tabs)

/// The two-tab preview (design §7). *What this means* is the plain-language
/// summary; *Raw data* is the literal serialized payload — the exact bytes the
/// uploader posts, not a mock. Showing the real bytes is the promise that earns
/// the right to collect logs.
private struct ProblemReportPreview: View {
    let report: ProblemReport
    var onClose: () -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case meaning = "What this means"
        case raw = "Raw data"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .meaning

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preview")
                    .font(XMOTheme.Typography.control)
                    .foregroundStyle(XMOTheme.TextColor.primary)
                Spacer()
                XMOIconButton(systemName: "xmark", label: "Close preview", action: onClose)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            XMODivider()

            ScrollView {
                switch tab {
                case .meaning: meaningTab
                case .raw: rawTab
                }
            }
        }
        .frame(width: 480, height: 560)
        .background(XMOTheme.Surface.window)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
    }

    private var meaningTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ProblemReportSummary.lines(for: report.health), id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 4))
                        .foregroundStyle(XMOTheme.TextColor.muted)
                        .padding(.top, 5)
                    Text(line)
                        .font(XMOTheme.Typography.body)
                        .foregroundStyle(XMOTheme.TextColor.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            Text("\(report.events.count) diagnostic events attached · \(report.environment.macModel) · macOS \(report.environment.macOSVersion) · \(report.environment.appVersion) (build \(report.environment.appBuild))")
                .font(XMOTheme.Typography.meta)
                .foregroundStyle(XMOTheme.TextColor.muted)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var rawTab: some View {
        Text(rawJSON)
            .font(XMOTheme.Typography.mono(10.5))
            .foregroundStyle(XMOTheme.TextColor.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }

    /// The literal bytes the uploader would post, rendered as text. Same encoder.
    private var rawJSON: String {
        guard let data = try? report.encoded() else { return "Could not serialize the report." }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Button style

/// Filled (Send/Done) or plain (Cancel) action button, matching the sheet chrome.
private struct ProblemReportButtonStyle: ButtonStyle {
    let filled: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(XMOTheme.Typography.control)
            .foregroundStyle(filled ? Color.white : XMOTheme.TextColor.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                filled ? XMOTheme.Accent.blue : XMOTheme.Surface.card3,
                in: RoundedRectangle(cornerRadius: XMOTheme.Radius.button)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? XMOTheme.Motion.pressScale : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: XMOTheme.Motion.hoverDuration),
                       value: configuration.isPressed)
    }
}
