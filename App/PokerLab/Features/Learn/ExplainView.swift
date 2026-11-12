import SwiftUI
import PokerCourse
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Asks Apple's on-device model to put a graded answer into plain language. The model only
/// sees the solver's numbers; a reply that names the wrong best option, never names the best
/// option, or uses a number the solver didn't give is withheld.
@MainActor @Observable
final class Explainer {
    enum State: Equatable { case idle, loading, done(String), withheld, failed }
    private(set) var state = State.idle

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }

    func explain(_ q: Question, choice: Int) async {
        state = .loading
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: ExplanationPrompt.instructions)
                let reply = try await session.respond(to: ExplanationPrompt.prompt(q, choice: choice),
                                                      options: GenerationOptions(temperature: 0))
                let text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
                state = ExplanationPrompt.accept(text, for: q) ? .done(text) : .withheld
            } catch {
                state = .failed
            }
            return
        }
        #endif
        state = .failed
    }
}

/// "Explain" button and the generated explanation, under the feedback panel.
struct ExplainSection: View {
    let question: Question
    let choice: Int
    @State private var explainer = Explainer()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch explainer.state {
            case .idle:
                Button {
                    Task { await explainer.explain(question, choice: choice) }
                } label: {
                    Label("Explain in plain words", systemImage: "sparkles")
                }
                .buttonStyle(OutlineButtonStyle(height: 40))
                .accessibilityIdentifier("lesson-explain")
            case .loading:
                HStack(spacing: 8) { ProgressView().tint(Theme.muted); Text("Thinking on device…").font(Theme.caption).foregroundStyle(Theme.muted) }
            case .done(let text):
                VStack(alignment: .leading, spacing: 6) {
                    Text(text).font(Theme.caption).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ai-explanation")
                    Text("Written on device by Apple Intelligence from the solver's numbers. If it disagrees with the feedback above, trust the feedback.")
                        .font(.caption2).foregroundStyle(Theme.faint)
                }
            case .withheld:
                Text("The on-device explanation didn't match the solver's result, so it isn't shown.")
                    .font(Theme.caption).foregroundStyle(Theme.muted)
            case .failed:
                Text("The on-device model couldn't write an explanation right now.").font(Theme.caption).foregroundStyle(Theme.muted)
            }
        }
    }
}
