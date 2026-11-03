import AppKit
import SwiftUI

/// "Local insertion", in Settings › Advanced: a switch that lets another
/// process on this Mac hand Blurt a finished transcript, which Blurt inserts
/// through the same injector a dictation lands through
/// (`LoopbackInsertListener`, whose doc comment is the wire format).
///
/// Off until the user turns it on, and the token row appears with it: a client
/// sends that token as its first line, so nothing reaches the injector by
/// finding the socket. Both controls are in Advanced rather than General
/// because this is a wiring-up affordance for a companion app, not part of
/// anyone's everyday setup.
struct LoopbackInsertSection: View {
  let coordinator: AppCoordinator

  @AppStorage(LoopbackInsertStore.enabledDefaultsKey) private var isOn = false
  @AppStorage(LoopbackInsertStore.tokenDefaultsKey) private var token = ""

  var body: some View {
    Section {
      Toggle(isOn: $isOn) {
        SettingLabel(
          title: "Accept text from this Mac", systemImage: "arrow.down.left.square",
          subtitle: "Lets a local app hand Blurt text to insert where you’re typing.")
      }
      .onChange(of: isOn) { _, isOn in
        // Minted here rather than at launch, so an install that never turns
        // this on never has a secret sitting in its defaults.
        if isOn, token.isEmpty { token = LoopbackInsertStore.freshToken() }
        coordinator.loopbackInsertChanged()
      }
      if isOn {
        SettingRow(
          title: "Socket", systemImage: "point.3.connected.trianglepath.dotted",
          subtitle: socketPath
        ) {
          Button("Copy Path") { copy(socketPath) }
        }
        SettingRow(
          title: "Token", systemImage: "key",
          subtitle: "Your client sends this as its first line."
        ) {
          // The token is never drawn, only copied: it is the one secret on
          // this pane, and a settings window is a screen-shared window.
          Button("Copy") { copy(token) }
          Button("Regenerate") {
            token = LoopbackInsertStore.freshToken()
            coordinator.loopbackInsertChanged()
          }
        }
      }
    } header: {
      Text("Local insertion")
    } footer: {
      if isOn {
        // No trailing period: the line ends on a path, which should select and
        // copy without picking up punctuation (the same rule the developer-mode
        // footer follows).
        Text(
          "Send newline-separated UTF-8 to the socket, the token first, then one transcript per "
            + "line with newlines written as \\n. Anything running as you can reach this socket")
      } else {
        Text("Off. A local app could otherwise type into whatever you have focused.")
      }
    }
  }

  private var socketPath: String { LoopbackInsertStore.socketURL.path(percentEncoded: false) }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}
