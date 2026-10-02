import BlurtDesign
import BlurtiOSCore
import SwiftUI
import UIKit

/// The easter egg: a 30-second typing sprint, full screen, from Settings. The
/// clock starts on the first keystroke, the last five seconds turn orange and
/// thump, and the result becomes the typing speed time saved is measured
/// against, in place of the 36 wpm phone average.
struct TypingTestView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private enum Phase: Equatable {
    case ready
    case running(since: Date)
    case finished(wordsPerMinute: Double, accuracy: Double, result: TypingSpeed.Result)

    var startDate: Date? {
      if case .running(let since) = self { return since }
      return nil
    }
  }

  @State private var test = TypingTest()
  @State private var phase = Phase.ready
  @State private var input = ""
  @State private var best = TypingSpeed.best()
  @FocusState private var isTyping: Bool

  private static let seconds = Double(TypingTest.duration.components.seconds)

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appSectionGap) {
      HStack {
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: DesignTokens.Metrics.appIcon, weight: DesignTokens.Typography.weightGlyph))
            .foregroundStyle(BlurtBrand.muted)
            .frame(width: DesignTokens.Metrics.appHeaderHeight, height: DesignTokens.Metrics.appHeaderHeight)
        }
        .accessibilityLabel("Close")
        Spacer()
        Eyebrow("How fast can you type?")
        Spacer()
        Color.clear.frame(width: DesignTokens.Metrics.appHeaderHeight, height: DesignTokens.Metrics.appHeaderHeight)
      }

      switch phase {
      case .ready, .running:
        sprint
      case .finished(let wordsPerMinute, let accuracy, let result):
        results(wordsPerMinute: wordsPerMinute, accuracy: accuracy, result: result)
      }
    }
    .padding(.horizontal, DesignTokens.Metrics.appPagePad)
    .page()
    .onAppear { isTyping = true }
    .task(id: phase.startDate) { await runClock() }
  }

  // MARK: - The sprint

  private var sprint: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appSectionGap) {
      TimelineView(.periodic(from: .now, by: DesignTokens.Motion.typingTick)) { context in
        let remaining = remainingSeconds(at: context.date)
        let isFinalStretch =
          phase.startDate != nil && remaining <= Double(TypingTest.finalStretch.components.seconds)
        HStack(alignment: .firstTextBaseline) {
          Text(String(format: "%.1f", remaining))
            .font(BlurtType.mono(DesignTokens.Typography.sizeTypingClock, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(isFinalStretch ? BlurtBrand.errorOrange : BlurtBrand.text)
            .scaleEffect(
              isFinalStretch && !reduceMotion && pulse(at: context.date) ? DesignTokens.Metrics.typingPulse : 1,
              anchor: .leading
            )
            .animation(.easeOut(duration: DesignTokens.Motion.typingFlash), value: Int(remaining))
          Spacer()
          VStack(alignment: .trailing, spacing: DesignTokens.Metrics.appLineGap) {
            Eyebrow("WPM")
            Text(liveWordsPerMinute(at: context.date))
              .font(BlurtType.mono(DesignTokens.Typography.sizeTypingLive, weight: .bold))
              .monospacedDigit()
              .foregroundStyle(BlurtBrand.accent)
          }
        }
        .accessibilityElement(children: .combine)
      }

      wordsText
        .font(BlurtType.mono(DesignTokens.Typography.sizeTypingWords, weight: .medium))
        .lineSpacing(DesignTokens.Metrics.typingLineSpacing)
        .frame(maxWidth: .infinity, minHeight: DesignTokens.Metrics.typingWordsHeight, alignment: .topLeading)
        .accessibilityLabel("Next word: \(test.currentWord)")

      TextField("Start typing to begin", text: $input)
        .font(BlurtType.mono(DesignTokens.Typography.sizeTypingField))
        .foregroundStyle(BlurtBrand.text)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.asciiCapable)
        .focused($isTyping)
        .padding(DesignTokens.Metrics.typingFieldPad)
        .background(BlurtBrand.cardFill, in: RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusInput))
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusInput)
            .strokeBorder(
              input.isEmpty || test.isOnTrack(input) ? BlurtBrand.cardBorder : BlurtBrand.errorOrange,
              lineWidth: DesignTokens.Metrics.typingFieldBorder)
        )
        .animation(.easeInOut(duration: DesignTokens.Motion.typingFlash), value: test.isOnTrack(input))
        .onChange(of: input) { _, typed in handle(typed) }

      Text(phase == .ready ? "30 seconds. The clock starts on your first key." : "Space after each word.")
        .brandFootnote()
      Spacer(minLength: 0)
    }
  }

  /// A stable block of words: it moves on in chunks of eight, so the words
  /// under your eyes don't jump while you type.
  private var wordsText: Text {
    let start = (test.index / 8) * 8
    var text = Text("")
    for position in start..<(start + 20) {
      var styled = Text(test.words[position % test.words.count])
      if position < test.index {
        styled =
          test.outcomes[position]
          ? styled.foregroundStyle(BlurtBrand.muted)
          : styled.foregroundStyle(BlurtBrand.errorOrange).strikethrough()
      } else if position == test.index {
        styled = styled.foregroundStyle(BlurtBrand.accent).bold().underline()
      } else {
        styled = styled.foregroundStyle(BlurtBrand.text)
      }
      text = text + styled + Text(" ")
    }
    return text
  }

  private func handle(_ typed: String) {
    if phase == .ready, !typed.isEmpty { phase = .running(since: .now) }
    guard case .running = phase, let last = typed.last, last.isWhitespace else { return }
    let word = typed.trimmingCharacters(in: .whitespaces)
    input = ""
    guard !word.isEmpty else { return }
    if test.submit(word) {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    } else {
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
  }

  /// Runs once per sprint: waits out the clock, thumps through the final
  /// stretch, then scores.
  private func runClock() async {
    guard let start = phase.startDate else { return }
    let stretch = Int(TypingTest.finalStretch.components.seconds)
    let untilStretch = start.addingTimeInterval(Self.seconds - Double(stretch)).timeIntervalSinceNow
    try? await Task.sleep(for: .seconds(max(0, untilStretch)))
    for _ in 0..<stretch {
      guard !Task.isCancelled else { return }
      UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 1)
      try? await Task.sleep(for: .seconds(1))
    }
    guard !Task.isCancelled else { return }
    finish()
  }

  private func finish() {
    let wordsPerMinute = test.wordsPerMinute(after: TypingTest.duration)
    let result = TypingSpeed.record(wordsPerMinute)
    best = TypingSpeed.best()
    isTyping = false
    input = ""
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    phase = .finished(wordsPerMinute: wordsPerMinute, accuracy: test.accuracy, result: result)
  }

  private func restart() {
    test = TypingTest()
    input = ""
    phase = .ready
    isTyping = true
  }

  private func remainingSeconds(at date: Date) -> Double {
    guard let start = phase.startDate else { return Self.seconds }
    return max(0, Self.seconds - date.timeIntervalSince(start))
  }

  private func liveWordsPerMinute(at date: Date) -> String {
    guard let start = phase.startDate else { return "--" }
    let elapsed = date.timeIntervalSince(start)
    // The first couple of seconds swing wildly, so hold off.
    guard elapsed >= 2 else { return "--" }
    return "\(Int(test.wordsPerMinute(after: .seconds(min(elapsed, Self.seconds))).rounded()))"
  }

  private func pulse(at date: Date) -> Bool {
    date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) < DesignTokens.Motion.typingFlash
  }

  // MARK: - The result

  private func results(wordsPerMinute: Double, accuracy: Double, result: TypingSpeed.Result) -> some View {
    let rank = TypingTest.rank(for: wordsPerMinute)
    let rounded = Int(wordsPerMinute.rounded())
    let speedup = TypingTest.speakingWordsPerMinute / max(wordsPerMinute, 1)
    return VStack(alignment: .leading, spacing: DesignTokens.Metrics.typingResultGap) {
      VStack(alignment: .leading, spacing: DesignTokens.Metrics.appChipGap) {
        Eyebrow(
          result.isBest ? "New personal best" : "Best \(Int(best.rounded())) wpm",
          color: result.isBest ? BlurtBrand.accent : BlurtBrand.muted)
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Metrics.appChipGap) {
          Text("\(rounded)")
            .font(BlurtType.mono(DesignTokens.Typography.sizeTypingResult, weight: .bold))
            .foregroundStyle(BlurtBrand.text)
          Text("WPM")
            .font(BlurtType.mono(DesignTokens.Typography.sizeTypingUnit, weight: .medium))
            .foregroundStyle(BlurtBrand.muted)
        }
        Text(rank.title)
          .font(BlurtType.heading(DesignTokens.Typography.sizeTypingRank))
          .foregroundStyle(BlurtBrand.text)
        Text(rank.line)
          .font(BlurtType.body(DesignTokens.Typography.sizeBody))
          .foregroundStyle(BlurtBrand.text)
      }
      .accessibilityElement(children: .combine)

      Eyebrow("\(Int((accuracy * 100).rounded()))% accuracy")

      Text(
        speedup >= 1.5
          ? "Talking runs about 150 words a minute. That's \(String(format: "%.1f", speedup))× you."
          : "Talking runs about 150 words a minute. Honestly, you might not need us."
      )
      .font(BlurtType.body(DesignTokens.Typography.sizeBody))
      .foregroundStyle(BlurtBrand.text)
      .fixedSize(horizontal: false, vertical: true)
      .padding(DesignTokens.Metrics.appCardPad)
      .frame(maxWidth: .infinity, alignment: .leading)
      .card()

      Eyebrow(
        result.setsSpeed
          ? "Time saved now uses your \(rounded) wpm" : "Too few words to measure. Time saved is unchanged",
        color: result.setsSpeed ? BlurtBrand.accent : BlurtBrand.muted)

      Button("Try again", action: restart)
        .buttonStyle(BrandButtonStyle())
      Spacer(minLength: 0)
    }
  }
}
