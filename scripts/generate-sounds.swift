#!/usr/bin/env swift  //  // Generate Blurt's record-start / record-stop cue WAVs for every selectable  // voice, rendered from two authentic vintage synths hosted as Audio Units:  //   • Yamaha DX7 via Dexed (aumu Dexd DGSB) — ROM1A/ROM1B factory cartridges  //     loaded as MIDI SysEx + program change.  //   • Roland Juno-106 via KR-106 (aumu Kr16 Krok) — the 128 authentic factory  //     presets, loaded by the AU's named factory presets.  //  // For each voice it schedules the cue notes, renders offline, mixes to mono,  // cosine-fades the tail (so truncation doesn't click), peak-normalizes the  // start/stop pair together, and writes a 44.1 kHz mono AAC .m4a (~3.5× smaller  // than the equivalent 16-bit WAV, to keep the app download small). It also emits  // SoundPackCatalog.swift (the app's voice list).
//
// BUILD-TIME ONLY: requires Dexed (https://asb2m10.github.io/dexed/) and KR-106
// (https://kayrock.org/kr106/) installed. Blurt needs neither to run — the
// rendered .m4a files are committed. CI does not run this script.
//
// Cues (strong start/stop contrast):
//   Start = rising minor sixth E4->C5, crescendo, ends on the HIGH tonic.
//   Stop  = falling major sixth A4->C4, gentle, ends a full octave lower.
//
// Usage: swift scripts/generate-sounds.swift
//
import AVFoundation

let sampleRate = 44100.0

func fourCC(_ s: String) -> FourCharCode {
  var r: FourCharCode = 0
  for b in s.utf8 { r = (r << 8) + FourCharCode(b) }
  return r
}

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let dx7Dir = scriptDir.appendingPathComponent("dx7")
let outDir = scriptDir.appendingPathComponent("../App/Blurt/Blurt/Resources/Sounds")
  .standardizedFileURL

struct Note {
  let midi: UInt8
  let start: Double  // seconds
  let dur: Double  // seconds the key is held; the voice rings out past this
  let vel: UInt8
}

// One sound pack = a cartridge + a voice within it. `name` is the WAV stem.
// Every ROM1A and ROM1B voice becomes a selectable pack. The cartridge id (e.g.
// "rom1a") + voice index is the stable pack id; the human label is the DX7
// voice name read from the .syx itself.
struct Cartridge {
  let id: String  // file under scripts/dx7 (without extension)
  let rom: String  // display/group name, e.g. "ROM1A"
}

let cartridges = [
  Cartridge(id: "rom1a", rom: "ROM1A"),
  Cartridge(id: "rom1b", rom: "ROM1B"),
]

// A DX7 32-voice bank is 6-byte header + 32*128 packed voices + checksum + F7.
// Each packed voice's name is its last 10 bytes (offset 118..128). Collapse the
// runs of padding spaces DX7 names carry, then title-case the all-caps ROM names
// so labels read cleanly ("BRASS   1" -> "Brass 1") and match the Juno voices.
func voiceName(_ bank: Data, _ voice: Int) -> String {
  let base = 6 + voice * 128 + 118
  let raw = String(decoding: bank[base..<(base + 10)], as: UTF8.self)
  let titled = raw.split(whereSeparator: { $0 == " " || $0 == "\0" }).joined(separator: " ")
    .trimmingCharacters(in: .whitespaces)
    .capitalized
  // `.capitalized` uppercases the first letter after a digit ("5THS" -> "5Ths");
  // keep ordinals lowercase ("5ths") by lowering any letter that follows a digit.
  var chars = Array(titled)
  for i in chars.indices where i > 0 && chars[i - 1].isNumber && chars[i].isUppercase {
    chars[i] = Character(chars[i].lowercased())
  }
  return String(chars)
}

// Renders one cue from any hosted instrument AU. `configure` selects the voice
// on the freshly-instantiated unit (DX7: send the cartridge SysEx + a program
// change; Juno: set the factory preset) before the notes are scheduled.
func renderSamples(
  component: AudioComponentDescription, notes: [Note], total: Double,
  configure: (_ core: AudioUnit, _ unit: AVAudioUnit) throws -> Void
) throws -> [Float] {
  let sema = DispatchSemaphore(value: 0)
  var instrument: AVAudioUnit?
  AVAudioUnit.instantiate(with: component, options: []) { u, _ in
    instrument = u
    sema.signal()
  }
  sema.wait()
  guard let instrument else { throw NSError(domain: "gen", code: 1) }

  let engine = AVAudioEngine()
  engine.attach(instrument)
  let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
  _ = engine.mainMixerNode
  engine.connect(instrument, to: engine.mainMixerNode, format: format)
  try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
  try engine.start()
  let au = instrument.audioUnit

  try configure(au, instrument)

  var events: [(frame: AVAudioFramePosition, go: () -> Void)] = []
  for n in notes {
    let on = AVAudioFramePosition(n.start * sampleRate)
    let off = AVAudioFramePosition((n.start + n.dur) * sampleRate)
    events.append((on, { MusicDeviceMIDIEvent(au, 0x90, UInt32(n.midi), UInt32(n.vel), 0) }))
    events.append((off, { MusicDeviceMIDIEvent(au, 0x80, UInt32(n.midi), 0, 0) }))
  }
  events.sort { $0.frame < $1.frame }

  let buffer = AVAudioPCMBuffer(
    pcmFormat: engine.manualRenderingFormat,
    frameCapacity: engine.manualRenderingMaximumFrameCount)!
  let totalFrames = AVAudioFramePosition(total * sampleRate)
  var rendered: AVAudioFramePosition = 0
  var ei = 0
  var samples: [Float] = []
  samples.reserveCapacity(Int(totalFrames))
  while rendered < totalFrames {
    while ei < events.count && events[ei].frame <= rendered {
      events[ei].go()
      ei += 1
    }
    let toNext = ei < events.count ? events[ei].frame - rendered : totalFrames - rendered
    let chunk = AVAudioFrameCount(
      max(1, min(AVAudioFramePosition(buffer.frameCapacity), toNext, totalFrames - rendered)))
    guard try engine.renderOffline(chunk, to: buffer) == .success else { break }
    if let ch = buffer.floatChannelData {
      let n = Int(buffer.frameLength)
      let chans = Int(buffer.format.channelCount)
      for i in 0..<n {
        var s: Float = 0
        for c in 0..<chans { s += ch[c][i] }
        samples.append(s / Float(chans))
      }
    }
    rendered += AVAudioFramePosition(buffer.frameLength)
  }
  engine.stop()

  let fadeIn = min(Int(0.003 * sampleRate), samples.count)
  let fadeOut = min(Int(0.03 * sampleRate), samples.count)
  for i in 0..<fadeIn { samples[i] *= Float(0.5 - 0.5 * cos(Double(i) / Double(fadeIn) * .pi)) }
  for i in 0..<fadeOut {
    samples[samples.count - 1 - i] *= Float(0.5 - 0.5 * cos(Double(i) / Double(fadeOut) * .pi))
  }

  return samples
}

func peak(_ samples: [Float]) -> Float { samples.reduce(0) { max($0, abs($1)) } }

func writePCMWAV(_ samples: [Float], to url: URL) throws {
  let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
  ]
  let monoFmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
  var outFile: AVAudioFile? = try AVAudioFile(
    forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
  let out = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: AVAudioFrameCount(samples.count))!
  out.frameLength = AVAudioFrameCount(samples.count)
  samples.withUnsafeBufferPointer { src in
    out.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
  }
  try outFile!.write(from: out)
  outFile = nil  // deinit finalizes the WAV header
}

func writeAAC(_ samples: [Float], to url: URL) throws {
  // AAC in an .m4a container — ~3.5× smaller than the equivalent 16-bit WAV with
  // no audible difference at cue lengths, and AVAudioPlayer decodes it up front
  // exactly like the old WAVs. Encoding goes through `afconvert`: writing AAC
  // directly via AVAudioFile leaves tens of KB of container slack per file (a
  // ~2 KB payload landed in a ~59 KB file), which would *grow* the bundle rather
  // than shrink it. `afconvert` packs the m4af tightly. Build-time only, macOS.
  let tmpWAV = url.deletingPathExtension().appendingPathExtension("tmp.wav")
  try writePCMWAV(samples, to: tmpWAV)
  defer { try? FileManager.default.removeItem(at: tmpWAV) }
  let proc = Process()
  proc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
  proc.arguments = ["-f", "m4af", "-d", "aac", tmpWAV.path, url.path]
  try proc.run()
  proc.waitUntilExit()
  guard proc.terminationStatus == 0 else {
    throw NSError(
      domain: "gen", code: Int(proc.terminationStatus),
      userInfo: [NSLocalizedDescriptionKey: "afconvert failed for \(url.lastPathComponent)"])
  }
}

// Shared gesture for every pack. Kept short: tight note spacing and a brief
// total so each cue reads as a quick UI blip rather than a melody.
let startNotes = [
  Note(midi: 64, start: 0.0, dur: 0.02, vel: 78),  // E4
  Note(midi: 72, start: 0.028, dur: 0.035, vel: 102),  // C5
]
let stopNotes = [
  Note(midi: 69, start: 0.0, dur: 0.02, vel: 86),  // A4
  Note(midi: 60, start: 0.032, dur: 0.045, vel: 78),  // C4
]

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Instruments vary widely in output level, so normalize every voice to a common
// peak. Normalize each voice's start+stop cues *together* (by their shared
// loudest peak) so all voices sit at the same level while the intended dynamic
// between the cues within a voice is preserved.
let targetPeak: Float = 0.8

let dexed = AudioComponentDescription(
  componentType: fourCC("aumu"), componentSubType: fourCC("Dexd"),
  componentManufacturer: fourCC("DGSB"), componentFlags: 0, componentFlagsMask: 0)
let juno = AudioComponentDescription(
  componentType: fourCC("aumu"), componentSubType: fourCC("Kr16"),
  componentManufacturer: fourCC("Krok"), componentFlags: 0, componentFlagsMask: 0)

var rows: [(id: String, label: String, group: String)] = []
var count = 0

// Render + normalize one voice's start/stop cues and record its catalog row.
func emit(
  id: String, label: String, group: String, component: AudioComponentDescription,
  configure: (AudioUnit, AVAudioUnit) throws -> Void
) throws {
  var startSamples = try renderSamples(component: component, notes: startNotes, total: 0.2, configure: configure)
  var stopSamples = try renderSamples(component: component, notes: stopNotes, total: 0.24, configure: configure)
  let loudest = max(peak(startSamples), peak(stopSamples))
  if loudest > 0 {
    let gain = targetPeak / loudest
    for i in startSamples.indices { startSamples[i] *= gain }
    for i in stopSamples.indices { stopSamples[i] *= gain }
  }
  try writeAAC(startSamples, to: outDir.appendingPathComponent("\(id)-start.m4a"))
  try writeAAC(stopSamples, to: outDir.appendingPathComponent("\(id)-stop.m4a"))
  rows.append((id: id, label: label, group: group))
  count += 2
}

// Yamaha DX7 — every ROM1A / ROM1B voice, loaded by cartridge SysEx + program change.
for cart in cartridges {
  let data = try Data(contentsOf: dx7Dir.appendingPathComponent("\(cart.id).syx"))
  for voice in 0..<32 {
    try emit(
      id: "\(cart.id)-\(voice)", label: voiceName(data, voice),
      group: "Yamaha DX7 · \(cart.rom)", component: dexed
    ) { core, _ in
      data.withUnsafeBytes {
        MusicDeviceSysEx(core, $0.bindMemory(to: UInt8.self).baseAddress!, UInt32(data.count))
      }
      MusicDeviceMIDIEvent(core, 0xC0, UInt32(voice), 0, 0)
    }
  }
}

// Roland Juno-106 (KR-106) — all 128 authentic factory presets, by name.
func junoPresetNames() throws -> [String] {
  let sema = DispatchSemaphore(value: 0)
  var unit: AVAudioUnit?
  AVAudioUnit.instantiate(with: juno, options: []) { u, _ in
    unit = u
    sema.signal()
  }
  sema.wait()
  return unit?.auAudioUnit.factoryPresets?.map { $0.name } ?? []
}
// Juno factory presets are named with a bank/patch code prefix ("A18 Piano I").
// Drop that prefix so the label is just the voice name ("Piano I").
func junoLabel(_ name: String) -> String {
  let parts = name.split(separator: " ", maxSplits: 1)
  if parts.count == 2, parts[0].count == 3, let first = parts[0].first,
    first == "A" || first == "B", parts[0].dropFirst().allSatisfy(\.isNumber)
  {
    return String(parts[1])
  }
  return name
}
let junoNames = try junoPresetNames()
for n in junoNames.indices {
  try emit(
    id: "juno-\(n)", label: junoLabel(junoNames[n]),
    group: "Roland Juno-106 · \(n < 64 ? "A" : "B")", component: juno
  ) { _, unit in
    let presets = unit.auAudioUnit.factoryPresets ?? []
    if n < presets.count { unit.auAudioUnit.currentPreset = presets[n] }
  }
}
print("wrote \(count) normalized cue .m4a files to \(outDir.path)")

// Emit the Swift catalog the app reads (one SoundPack per voice).
let catalogURL = scriptDir.appendingPathComponent("../Sources/BlurtEngine/Audio/SoundPackCatalog.swift")
  .standardizedFileURL
func swiftString(_ s: String) -> String {
  "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    + "\""
}
var lines: [String] = [
  "// Generated by scripts/generate-sounds.swift — do not edit by hand.",
  "// One SoundPack per voice (Yamaha DX7 ROM1A/1B, then Roland Juno-106).",
  "",
  "extension SoundPack {",
  "  /// Every selectable voice, grouped by synth, in render order.",
  "  public static let catalog: [SoundPack] = [",
]
for r in rows {
  lines.append(
    "    SoundPack(id: \(swiftString(r.id)), label: \(swiftString(r.label)), "
      + "group: \(swiftString(r.group))),")
}
lines.append("  ]")
lines.append("}")
try (lines.joined(separator: "\n") + "\n").write(to: catalogURL, atomically: true, encoding: .utf8)
print("wrote catalog (\(rows.count) voices) to \(catalogURL.path)")
