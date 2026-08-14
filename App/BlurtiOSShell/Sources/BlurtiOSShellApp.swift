import BlurtEngine
import SwiftUI

/// The whole iOS shell: one scene, one view, no behaviour.
///
/// It is not a product. It exists so CI has something that must *link*
/// `BlurtEngine` into an iOS application bundle. `ios-build`'s first step
/// compiles the library for the iOS SDK, which proves the source is iOS-clean;
/// it does not prove that an iOS consumer can resolve the symbols it reaches
/// for. That is a different failure, and only an app catches it.
///
/// Deliberately absent, and to stay that way: microphone capture, permission
/// prompts, `UIBackgroundModes`, entitlements, a signing identity, an Info.plist
/// of its own. Every one of those is a capability this probe would have to
/// justify, and none of them make the link claim any stronger.
@main
struct BlurtiOSShellApp: App {
  var body: some Scene {
    WindowGroup {
      EngineProbeView()
    }
  }
}

/// Renders values the engine computes, which is the part that does the work.
///
/// A shell that imports `BlurtEngine` and then touches nothing links cleanly
/// even when the linker drops the engine entirely — `DEAD_CODE_STRIPPING` is on
/// (see project.yml), so an unreferenced dependency proves only that the module
/// interface parsed. Each property below is therefore a real cross-module call
/// whose result reaches the view body, so it survives to the linked binary:
///
/// - `SetupReadiness.isReady(permissions:hasAPIKey:)` over a `PermissionStatus`.
///   That pair is what the iOS build already tripped over once, when
///   `PermissionStatus` was still inside `PermissionsChecker.swift`'s
///   `#if os(macOS)` fence — so it doubles as a regression probe on the fencing.
/// - `TriggerKey.fromPersisted(_:)` and its `label`, from the hotkey layer.
/// - `SyncSTTLimits.autoReleaseSeconds`, from the STT layer.
///
/// All three are pure value-type logic: no device, no keychain, no defaults,
/// nothing that needs a grant or a running service. Pick replacements with the
/// same property if these ever move.
struct EngineProbeView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("BlurtEngine linked")
      Text("setup ready: \(isConfigured)")
      Text("trigger key: \(triggerLabel)")
      Text("auto-release: \(autoReleaseSeconds) s")
    }
    .padding()
  }

  /// The engine's "fully configured" rule, run over a synthetic all-granted
  /// reading rather than a real one — iOS has neither of these grants to read.
  private var isConfigured: Bool {
    let permissions = PermissionStatus(microphone: true, accessibility: true)
    return SetupReadiness.isReady(permissions: permissions, hasAPIKey: true)
  }

  /// The engine's decode-with-default for a persisted trigger keycode.
  private var triggerLabel: String {
    TriggerKey.fromPersisted(TriggerKey.rightCommand.rawValue).label
  }

  /// When a held trigger auto-releases, derived by the engine from the Sync STT
  /// model's own cap.
  private var autoReleaseSeconds: Double {
    SyncSTTLimits.autoReleaseSeconds
  }
}
