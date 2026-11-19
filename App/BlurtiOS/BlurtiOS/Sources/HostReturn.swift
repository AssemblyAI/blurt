import Foundation
import ObjectiveC

/// Brings the app the keyboard was in back to the front once the hop has
/// opened the window — so a session turned on from the keyboard costs one
/// flash of Blurt and no swipe, as Typeless does it (`HopReturn` says when;
/// `BlurtShared.hopHost` says which app).
///
/// iOS has no public call for this: `UIApplication.open` needs a URL scheme
/// the host may not have, and the "◀ App" link is the user's to tap. What
/// works is `LSApplicationWorkspace`'s `openApplicationWithBundleID:`, which
/// a sandboxed app may call for an app that is installed (observed from
/// Typeless on iOS 18.7.8: `Received request to open "com.apple.MobileSMS"
/// from lsd`). Private, so it is looked up by name at run time and called
/// through the method's own implementation, and `false` when any step of
/// that is not there — the app then stays in front with its "◀" hint, as
/// before. App Review scans for these names; shipping this is a decision
/// taken knowingly, not a side effect.
enum HostReturn {
  private static let workspaceClassName = "LSApplicationWorkspace"
  private static let defaultWorkspace = NSSelectorFromString("defaultWorkspace")
  private static let openByBundleID = NSSelectorFromString("openApplicationWithBundleID:")
  private typealias Open = @convention(c) (NSObject, Selector, NSString) -> Bool

  /// Asks iOS to bring `bundleID` to the front; whether it agreed.
  static func open(bundleID: String) -> Bool {
    guard
      let workspaceClass = NSClassFromString(workspaceClassName) as? NSObject.Type,
      workspaceClass.responds(to: defaultWorkspace),
      let workspace = workspaceClass.perform(defaultWorkspace)?.takeUnretainedValue() as? NSObject,
      workspace.responds(to: openByBundleID),
      let implementation = class_getMethodImplementation(type(of: workspace), openByBundleID)
    else { return false }
    let open = unsafeBitCast(implementation, to: Open.self)
    return open(workspace, openByBundleID, bundleID as NSString)
  }
}
