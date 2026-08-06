import AppKit
import SwiftUI

/// "Report a problem" (#84, design §7): a free-text field, an honest manifest of
/// what is and isn't attached, and a two-tab preview — *What this means* (the
/// snapshot in plain sentences) and *Raw data* (the exact bytes to be sent). The
/// diagnostic payload is mandatory, not a toggle: the checkmarks state facts.
///
/// All build/send logic lives in `ProblemReportComposer`, which freezes the
/// diagnostics once so the previewed bytes are byte-for-byte the posted bytes.
/// Dark-only, LoreTheme tokens (D-031). Presented as a sheet from the health
/// panel and from Settings.
struct ProblemReportView: View {
    @State private var composer: ProblemReportComposer
    @State private var showPreview = false
    var onClose: () -> Void

    init(healthMonitor: HealthMonitor, uploader: ReportUploader = ReportUploader(), onClose: @escaping () -> Void) {
        _composer = State(initialValue: ProblemReportComposer(healthMonitor: healthMonitor, uploader: uploader))
        self.onClose = onClose
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
        @Bindable var composer = composer
        return VStack(spacing: 0) {
            header
            LoreDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    prompt(text: $composer.message)
                    manifest
                    footerStatus
                }
                .padding(20)
            }
            LoreDivider()
            actions
        }
        .frame(width: 460, height: 560)
        .background(LoreTheme.Surface.window)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
        // Freeze the diagnostics once, as the flow opens — the single probe.
        .onAppear { composer.prepare() }
        .sheet(isPresented: $showPreview) {
            ProblemReportPreview(report: composer.report(), onClose: { showPreview = false })
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Report a problem")
                    .font(LoreTheme.Typography.control)
                    .foregroundStyle(LoreTheme.TextColor.primary)
                Text("Sends a diagnostic report so we can see what your Mac saw.")
                    .font(LoreTheme.Typography.meta)
                    .foregroundStyle(LoreTheme.TextColor.muted)
            }
            Spacer()
            LoreIconButton(systemName: "xmark", label: "Close report", action: onClose)
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
    }

    // MARK: - Prompt

    private func prompt(text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LoreSectionLabel(text: "What happened?")
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text("Describe what went wrong — e.g. the Fn key stopped inserting text after a meeting.")
                        .font(LoreTheme.Typography.body)
                        .foregroundStyle(LoreTheme.TextColor.faint)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(LoreTheme.Typography.body)
                    .foregroundStyle(LoreTheme.TextColor.primary)
                    .scrollContentBackground(.hidden)
                    .frame(height: 96)
                    .padding(4)
            }
            .background(LoreTheme.Surface.card3, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.chip))
            .disabled(composer.phase == .sending)
        }
    }

    // MARK: - Manifest

    private var manifest: some View {
        VStack(alignment: .leading, spacing: 8) {
            LoreSectionLabel(text: "What gets sent")
            LoreCard {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Self.attached, id: \.self) { manifestRow(icon: "checkmark", color: LoreTheme.Accent.green, text: $0) }
                    ForEach(Self.notAttached, id: \.self) { manifestRow(icon: "xmark", color: LoreTheme.TextColor.muted, text: $0) }
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
                .font(LoreTheme.Typography.meta)
                .foregroundStyle(LoreTheme.Accent.blue)
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
                .font(LoreTheme.Typography.meta)
                .foregroundStyle(LoreTheme.TextColor.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Status (sent / failed)

    @ViewBuilder
    private var footerStatus: some View {
        switch composer.phase {
        case .sent(let id):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LoreTheme.Accent.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Report \(id) sent")
                        .font(LoreTheme.Typography.control)
                        .foregroundStyle(LoreTheme.TextColor.primary)
                    Text("Quote this ID to us and we'll find it.")
                        .font(LoreTheme.Typography.meta)
                        .foregroundStyle(LoreTheme.TextColor.muted)
                }
                Spacer(minLength: 0)
                LoreCopyButton(label: "Copy report ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(id, forType: .string)
                }
            }
            .padding(12)
            .background(LoreTheme.Surface.card2, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.card))
        case .failed(let error):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LoreTheme.Accent.amber)
                Text(error)
                    .font(LoreTheme.Typography.meta)
                    .foregroundStyle(LoreTheme.TextColor.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(LoreTheme.Surface.card2, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.card))
        case .editing, .sending:
            EmptyView()
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer()
            if case .sent = composer.phase {
                Button("Done", action: onClose)
                    .buttonStyle(ProblemReportButtonStyle(filled: true))
            } else {
                Button("Cancel", action: onClose)
                    .buttonStyle(ProblemReportButtonStyle(filled: false))
                    .disabled(composer.phase == .sending)
                Button(sendLabel) { Task { await composer.send() } }
                    .buttonStyle(ProblemReportButtonStyle(filled: true))
                    .disabled(!composer.canSend)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
    }

    private var sendLabel: String {
        switch composer.phase {
        case .sending: return "Sending…"
        case .failed: return "Try again"
        default: return "Send report"
        }
    }
}

// MARK: - Preview sheet (two tabs)

/// The two-tab preview (design §7). *What this means* is the plain-language
/// summary; *Raw data* is the literal serialized payload — the exact bytes the
/// uploader posts, not a mock. It renders the same frozen `report` instance the
/// uploader receives, so the tab and the POST cannot disagree.
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
                    .font(LoreTheme.Typography.control)
                    .foregroundStyle(LoreTheme.TextColor.primary)
                Spacer()
                LoreIconButton(systemName: "xmark", label: "Close preview", action: onClose)
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

            LoreDivider()

            ScrollView {
                switch tab {
                case .meaning: meaningTab
                case .raw: rawTab
                }
            }
        }
        .frame(width: 480, height: 560)
        .background(LoreTheme.Surface.window)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
    }

    private var meaningTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ProblemReportSummary.lines(for: report.health), id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 4))
                        .foregroundStyle(LoreTheme.TextColor.muted)
                        .padding(.top, 5)
                    Text(line)
                        .font(LoreTheme.Typography.body)
                        .foregroundStyle(LoreTheme.TextColor.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            Text("\(report.events.count) diagnostic events attached · \(report.environment.macModel) · macOS \(report.environment.macOSVersion) · \(report.environment.appVersion) (build \(report.environment.appBuild))")
                .font(LoreTheme.Typography.meta)
                .foregroundStyle(LoreTheme.TextColor.muted)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var rawTab: some View {
        Text(rawJSON)
            .font(LoreTheme.Typography.mono(10.5))
            .foregroundStyle(LoreTheme.TextColor.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }

    /// The literal bytes the uploader would post, rendered as text. Same encoder,
    /// same frozen `report` instance the uploader receives.
    private var rawJSON: String {
        guard let data = try? report.encoded() else { return "Could not serialize the report." }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Button style

/// Filled (Send/Done) or plain (Cancel) action button. The press scale/animation
/// is `LorePressButtonStyle`'s job — this only adds the filled/plain background.
private struct ProblemReportButtonStyle: ButtonStyle {
    let filled: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        LorePressButtonStyle().makeBody(configuration: configuration)
            .font(LoreTheme.Typography.control)
            .foregroundStyle(filled ? Color.white : LoreTheme.TextColor.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                filled ? LoreTheme.Accent.blue : LoreTheme.Surface.card3,
                in: RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
            )
            .opacity(isEnabled ? 1 : 0.4)
    }
}
