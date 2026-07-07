#!/usr/bin/env swift
// Captures a single app window to PNG with the macOS corner radius + drop
// shadow preserved in the alpha channel — exactly the input
// scripts/beautify.swift composites onto the gradient backdrop.
//
// Needs Screen Recording permission (System Settings → Privacy & Security);
// screencapture prompts for it on first use.
//
// Usage: swift scripts/screenshot.swift <app name> <out.png> [window title substring]
//   swift scripts/screenshot.swift Blurt /tmp/blurt.png
//   swift scripts/screenshot.swift Blurt /tmp/settings.png Settings

import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4 else {
  print("usage: screenshot.swift <app name> <out.png> [window title substring]")
  exit(1)
}
let appName = args[1]
let outputPath = args[2]
let titleFilter = args.count == 4 ? args[3] : nil

// On-screen windows, front to back. Layer 0 keeps ordinary document/settings
// windows and drops menu bar extras, overlays, and the Dock; the size floor
// drops helper popovers.
guard
  let windowList = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
else {
  print("could not read the window list")
  exit(1)
}

struct Candidate {
  let id: Int
  let title: String
  let width: Int
  let height: Int
}

let candidates: [Candidate] = windowList.compactMap { info in
  guard let owner = info[kCGWindowOwnerName as String] as? String, owner == appName,
    let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
    let id = info[kCGWindowNumber as String] as? Int,
    let bounds = info[kCGWindowBounds as String] as? [String: Any],
    let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
    width >= 64, height >= 64
  else { return nil }
  // Window titles are only visible here once Screen Recording is granted —
  // the same permission screencapture itself needs below.
  let title = info[kCGWindowName as String] as? String ?? ""
  return Candidate(id: id, title: title, width: Int(width), height: Int(height))
}

let matches: [Candidate]
if let titleFilter {
  matches = candidates.filter { $0.title.localizedCaseInsensitiveContains(titleFilter) }
} else {
  matches = candidates
}

guard let window = matches.first else {
  let filterNote = titleFilter.map { " with title containing \"\($0)\"" } ?? ""
  print("no on-screen window matched app \"\(appName)\"\(filterNote)")
  for c in candidates {
    let title = c.title.isEmpty ? "(untitled — grant Screen Recording to see titles)" : c.title
    print("  [\(c.id)] \(title) \(c.width)x\(c.height)")
  }
  exit(1)
}

// screencapture keeps the window's rounded corners and drop shadow in the
// PNG's alpha channel by default (-o would strip the shadow, which beautify
// relies on); -x mutes the shutter sound.
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
task.arguments = ["-x", "-t", "png", "-l", String(window.id), outputPath]
do {
  try task.run()
} catch {
  print("could not launch screencapture: \(error.localizedDescription)")
  exit(1)
}
task.waitUntilExit()
guard task.terminationStatus == 0, FileManager.default.fileExists(atPath: outputPath) else {
  print("screencapture failed — is Screen Recording granted in System Settings?")
  exit(1)
}
let titleNote = window.title.isEmpty ? "" : " — \(window.title)"
print("captured \"\(appName)\"\(titleNote) (\(window.width)x\(window.height)) to \(outputPath)")
