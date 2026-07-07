import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentStep = 0

    private let steps: [(icon: String, title: String, body: String)] = [
        (
            "waveform.circle",
            "Welcome to \(XMOTheme.wordmark)",
            "A real-time meeting companion that transcribes your conversations and writes meeting notes — all running locally on your Mac."
        ),
        (
            "text.quote",
            "Live Transcript",
            "Your conversation is transcribed in real time. \"You\" captures your mic, \"Them\" captures system audio from the other side. Expand the transcript panel to follow along."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon
            Image(systemName: steps[currentStep].icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(XMOTheme.Accent.blue)
                .frame(height: 52)
                .id(currentStep) // force transition on change

            Spacer().frame(height: 20)

            // Title
            Text(steps[currentStep].title)
                .font(XMOTheme.Typography.heading)
                .foregroundStyle(XMOTheme.TextColor.primary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 10)

            // Body
            Text(steps[currentStep].body)
                .font(XMOTheme.Typography.body)
                .foregroundStyle(XMOTheme.TextColor.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            XMOStepDots(count: steps.count, current: currentStep)
                .padding(.bottom, 20)

            XMOOnboardingFooter(
                leadingTitle: "Skip",
                leadingAction: finish,
                step: currentStep,
                count: steps.count,
                advance: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentStep += 1
                    }
                },
                finish: finish
            )
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(XMOTheme.Surface.window)
        .background(.ultraThinMaterial)
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.2)) {
            isPresented = false
        }
    }
}
