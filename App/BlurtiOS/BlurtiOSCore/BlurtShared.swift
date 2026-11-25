import Foundation

// MARK: - The App Group contract

/// What the Blurt app and the Blurt keyboard agree on. They are two processes:
/// the app listens and transcribes (iOS lets no keyboard use the microphone),
/// the keyboard drops the words into the field it is attached to. They talk
/// through the App Group's shared defaults and wake each other with Darwin
/// notifications — a system-wide "something changed" ping that carries no data,
/// so every payload lives in the defaults under one of the keys below.
package nonisolated enum BlurtShared {
  package nonisolated enum Key {
    package static let autoDictate = "autoDictate"
    package static let listeningUntil = "listeningUntil"
    package static let windowMinutes = "listeningWindowMinutes"
    /// "Use AirPods mic": the session allows a Bluetooth microphone.
    package static let airPodsMic = "airPodsMic"
    package static let phase = "phase"
    package static let command = "command"
    package static let result = "result"
    package static let keyboardSeenAt = "keyboardSeenAt"
    package static let keyboardInstance = "keyboardInstance"
    package static let appSeenAt = "appSeenAt"
    package static let keyboardEverSeen = "keyboardEverSeen"
    package static let lexicon = "lexicon"
    package static let lexiconRefreshedAt = "lexiconRefreshedAt"
    /// The session contract (`BlurtShared+SessionContract.swift`).
    package static let listeningState = "listeningState"
    package static let ack = "commandAck"
    package static let keyboardPresence = "keyboardPresence"
  }

  /// Darwin notification names. Reverse-DNS so they can't collide with another
  /// app's on the same device.
  package nonisolated enum Signal {
    package static let command = "com.assemblyai.blurt.iphone.command"
    package static let phase = "com.assemblyai.blurt.iphone.phase"
    package static let result = "com.assemblyai.blurt.iphone.result"
    package static let lexicon = "com.assemblyai.blurt.iphone.lexicon"
    /// The app's `ListeningState` changed: opened, closed, interrupted, relaunched.
    package static let state = "com.assemblyai.blurt.iphone.state"
    /// The app answered a command (`CommandAck`).
    package static let ack = "com.assemblyai.blurt.iphone.ack"
    /// A keyboard appeared or left (`KeyboardPresenceRecord`).
    package static let keyboard = "com.assemblyai.blurt.iphone.keyboard"
  }

  /// The App Group both targets declare. A placeholder namespace inherited from
  /// the Mac app; an org-owned id replaces it before the App Store, and the app
  /// and the keyboard must change together.
  package static let appGroup = "group.com.assemblyai.blurt.iphone"
  /// The URL the keyboard opens to bring the app forward (`blurt://start`) —
  /// the one moment iOS insists on before the microphone may open.
  package static let urlScheme = "blurt"
  package static let startHost = "start"
  /// A press command older than this was held while the app was suspended:
  /// the app drops it unanswered, and the keyboard stops waiting for an answer.
  package static let commandFreshnessWindow: TimeInterval = 10
}
