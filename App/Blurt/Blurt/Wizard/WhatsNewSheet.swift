import BlurtEngine
import SwiftUI

extension Changelog {
  /// The release notes the app ships: the repo's `CHANGELOG.md`, copied into the
  /// bundle by the "Bundle CHANGELOG.md" build phase (`project.yml`). Read once;
  /// a missing file reads as no notes, which shows no sheet.
  static let bundled = Changelog(
    markdown: Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
      .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
}

/// One presentation of the What's New sheet, set on `AppDelegate.whatsNew`.
/// Identifiable so `.sheet(item:)` keeps showing it while the sheet animates out;
/// `nonisolated` so that conformance isn't main-actor-isolated by the target's
/// default isolation.
nonisolated struct WhatsNewRequest: Identifiable {
  let id = UUID()
  /// Newest first — more than one only after skipping a version.
  let entries: [ChangelogEntry]
}

/// The release notes shown on the first launch after an update, and again from
/// Help → What's New in Blurt. Which notes, and when, is the engine's call
/// (`Changelog.whatsNewAtLaunch`); the wording is `CHANGELOG.md`'s.
///
/// Same shape as `APIKeyEditorSheet`: headline, content, then a button row with
/// the secondary action at the leading edge and the default one trailing, so
/// Return dismisses.
struct WhatsNewSheet: View {
  let entries: [ChangelogEntry]

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      // One release fits as is; several (after skipping versions) scroll rather
      // than grow the sheet past the window.
      if entries.count > 1 {
        ScrollView { notes }
          .frame(height: 480)
      } else {
        notes
      }

      HStack {
        if let url = BlurtLinks.releases {
          Link("See all releases", destination: url)
            .foregroundStyle(BlurtBrand.accent)
        }
        Spacer(minLength: 12)
        Button("Continue") { dismiss() }
          .glassButtonStyleCompat(prominent: true)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 440)
  }

  private var notes: some View {
    VStack(alignment: .leading, spacing: 28) {
      ForEach(entries, id: \.title) { ReleaseNotes(entry: $0) }
    }
  }
}

/// One release: title and date, the headline features, then the fixes.
private struct ReleaseNotes: View {
  let entry: ChangelogEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title)
          .font(.title2.bold())
        if let date = entry.dateLabel {
          Text(date)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      if !entry.features.isEmpty {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(entry.features, id: \.title) { FeatureRow(feature: $0) }
        }
      }

      if !entry.fixes.isEmpty {
        fixes
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var fixes: some View {
    VStack(alignment: .leading, spacing: 7) {
      Divider()
        .padding(.bottom, 9)
      Text("Fixes")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 5) {
        ForEach(entry.fixes, id: \.self) { fix in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The bullet is decoration, so VoiceOver skips it.
            Text("•")
              .foregroundStyle(.tertiary)
              .accessibilityHidden(true)
            Text(fix)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .font(.callout)
    }
  }
}

/// A headline feature: its symbol in the brand accent, like the settings rows'
/// glyphs, beside a bold title and a secondary sentence.
private struct FeatureRow: View {
  let feature: ChangelogEntry.Feature

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: feature.symbolName)
        .font(.title2)
        .foregroundStyle(BlurtBrand.accent)
        .frame(width: 28)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(feature.title)
          .fontWeight(.semibold)
        Text(feature.summary)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
