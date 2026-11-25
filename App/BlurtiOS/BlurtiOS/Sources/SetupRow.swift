import AVFoundation
import BlurtDesign
import SwiftUI

/// One step: its number in mono, the step, and its control while it is still
/// to do; a check when done.
struct SetupRow<Action: View>: View {
  let number: String
  let done: Bool
  let title: String
  @ViewBuilder let action: () -> Action

  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Metrics.appStackGap) {
      Eyebrow(number, color: done ? BlurtBrand.accent : BlurtBrand.muted)
        .frame(width: DesignTokens.Metrics.appSetupNumberWidth, alignment: .leading)
      VStack(alignment: .leading, spacing: DesignTokens.Metrics.appLineGap) {
        HStack {
          Text(title).font(BlurtType.body(DesignTokens.Typography.sizeBody)).foregroundStyle(BlurtBrand.text)
          // The only sign a step is finished (its control goes away), so VoiceOver reads it.
          if done { Image(systemName: "checkmark").foregroundStyle(BlurtBrand.accent).accessibilityLabel("Done") }
        }
        if !done { action() }
      }
    }
  }
}
