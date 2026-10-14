import Foundation

/// The user's go-ahead to send their voice, and the text that gives it context,
/// to AssemblyAI. App Review 5.1.2(i) requires clearly disclosing where personal
/// data goes, third-party AI included, and getting explicit permission first, so
/// the listening window won't open until this is granted.
///
/// Versioned: consent covers what is sent, so sending something new (another
/// kind of context) means raising `version` and updating the copy that lists it
/// (`ConsentView`), and everyone is asked again.
package nonisolated enum AIConsent {
  /// The version of the disclosure in `ConsentView`: 1 is audio, the text before
  /// the cursor, recent dictations, and key terms with contact names.
  package static let version = 1
  package static let defaultsKey = "AIConsentVersion"
  package static let privacyPolicyURL =
    URL(string: "https://www.assemblyai.com/legal/privacy-policy") ?? URL(filePath: "/")

  /// Whether the user agreed to the current disclosure. Agreeing to an older one
  /// isn't enough: it didn't list everything that is sent now.
  package static func isGranted(in defaults: UserDefaults = .standard) -> Bool {
    defaults.integer(forKey: defaultsKey) >= version
  }

  package static func grant(in defaults: UserDefaults = .standard) {
    defaults.set(version, forKey: defaultsKey)
  }
}
