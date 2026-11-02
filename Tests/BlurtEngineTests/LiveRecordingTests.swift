import AVFoundation
import CoreAudio
import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// The Record button's pieces that run without hardware or a socket: the
/// recorder's mic + system mix and its 16-bit output, how realtime turns fold
/// into the live transcript, and how `Turn` messages decode.
@Suite("Live recording")
struct LiveRecordingTests {
  // MARK: - Recorder mix

  @Test("each stream is averaged to mono, then the mic and system streams are summed and clamped")
  func mixToMono() {
    var mic: [Float] = [0.25, 0.5]  // mono
    var system: [Float] = [0.5, 0.5, 1, 1]  // stereo, interleaved: two frames
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(list.unsafeMutablePointer) }
    mic.withUnsafeMutableBytes { micBytes in
      system.withUnsafeMutableBytes { systemBytes in
        list[0] = AudioBuffer(
          mNumberChannels: 1, mDataByteSize: UInt32(micBytes.count), mData: micBytes.baseAddress)
        list[1] = AudioBuffer(
          mNumberChannels: 2, mDataByteSize: UInt32(systemBytes.count), mData: systemBytes.baseAddress)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        defer { out.deallocate() }
        let frames = MixWriter.mix(list, into: out, capacity: 8)
        #expect(Array(UnsafeBufferPointer(start: out, count: frames)) == [0.75, 1])
      }
    }
  }

  @Test("the mix is capped at the buffer's capacity")
  func mixCapacity() {
    var mic: [Float] = [0.1, 0.2, 0.3, 0.4]
    let list = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(list.unsafeMutablePointer) }
    mic.withUnsafeMutableBytes { bytes in
      list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
      let out = UnsafeMutablePointer<Float>.allocate(capacity: 2)
      defer { out.deallocate() }
      #expect(MixWriter.mix(list, into: out, capacity: 2) == 2)
    }
  }

  @Test("a 48 kHz cycle comes out as 16 kHz PCM and lands in a playable AAC file")
  func mixWriterEndToEnd() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MixWriterTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "mix.m4a")
    let emitted = Mutex(0)
    let writer = try MixWriter(url: url, inputRate: 48_000, maxFrames: 512) { pcm in
      emitted.withLock { $0 += pcm.count }
    }
    // A second of audio in 480-frame cycles: a mono mic and a stereo tap.
    var mic = [Float](repeating: 0.2, count: 480)
    var tap = [Float](repeating: 0.1, count: 960)
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(list.unsafeMutablePointer) }
    for _ in 0..<100 {
      mic.withUnsafeMutableBytes { micBytes in
        tap.withUnsafeMutableBytes { tapBytes in
          list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(micBytes.count), mData: micBytes.baseAddress)
          list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(tapBytes.count), mData: tapBytes.baseAddress)
          writer.write(UnsafePointer(list.unsafeMutablePointer))
        }
      }
    }
    writer.close()
    // One second at 16 kHz × 2 bytes, less what the resampler still holds.
    #expect(abs(emitted.withLock { $0 } - 32_000) < 1_000)
    let file = try AVAudioFile(forReading: url)
    #expect(file.fileFormat.sampleRate == SystemAudioRecorder.outputSampleRate)
    #expect(file.fileFormat.channelCount == 1)
    #expect(file.length > 12_000)
  }

  @Test("after close, a late cycle is ignored")
  func writerIgnoresAfterClose() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MixWriterTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let emitted = Mutex(0)
    let writer = try MixWriter(url: directory.appending(path: "mix.m4a"), inputRate: 16_000, maxFrames: 256) { _ in
      emitted.withLock { $0 += 1 }
    }
    writer.close()
    var mic = [Float](repeating: 0.2, count: 160)
    let list = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(list.unsafeMutablePointer) }
    mic.withUnsafeMutableBytes { bytes in
      list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
      writer.write(UnsafePointer(list.unsafeMutablePointer))
    }
    #expect(emitted.withLock { $0 } == 0)
  }

  // MARK: - Live transcript

  @Test("a turn's partials are replaced by its final; the next turn's partial shows apart")
  func liveTranscript() {
    var live = LiveTranscript()
    live.apply(RealtimeTurn(order: 0, transcript: "hello", isFinal: false, speaker: nil))
    #expect(live.partial == "hello")
    #expect(live.text.isEmpty)
    live.apply(RealtimeTurn(order: 0, transcript: "Hello there.", isFinal: true, speaker: nil))
    live.apply(RealtimeTurn(order: 1, transcript: "how are", isFinal: false, speaker: nil))
    #expect(live.text == "Hello there.")
    #expect(live.partial == "how are")
    live.apply(RealtimeTurn(order: 1, transcript: "How are you?", isFinal: true, speaker: nil))
    #expect(live.text == "Hello there.\n\nHow are you?")
    #expect(live.partial == nil)
  }

  @Test("with more than one speaker, a labelled paragraph per change of speaker")
  func liveSpeakers() {
    var live = LiveTranscript()
    live.apply(RealtimeTurn(order: 0, transcript: "Hi.", isFinal: true, speaker: "A"))
    live.apply(RealtimeTurn(order: 1, transcript: "Shall we start?", isFinal: true, speaker: "A"))
    live.apply(RealtimeTurn(order: 2, transcript: "Sure.", isFinal: true, speaker: "B"))
    #expect(live.text == "Speaker A: Hi. Shall we start?\n\nSpeaker B: Sure.")
    // The same words, unlabelled: a paragraph per turn.
    #expect(live.plainText == "Hi.\n\nShall we start?\n\nSure.")
  }

  @Test("Turn messages decode; Begin and other types carry no turn")
  func realtimeEvents() throws {
    let turn = try JSONDecoder().decode(
      RealtimeTranscriber.Event.self,
      from: Data(
        #"{"type":"Turn","turn_order":3,"transcript":"Ship it","end_of_turn":true,"speaker_label":"B","words":[]}"#
          .utf8))
    #expect(turn.turn == RealtimeTurn(order: 3, transcript: "Ship it", isFinal: true, speaker: "B"))
    let begin = try JSONDecoder().decode(
      RealtimeTranscriber.Event.self, from: Data(#"{"type":"Begin","id":"x","expires_at":1}"#.utf8))
    #expect(begin.type == "Begin")
    #expect(begin.turn == nil)
  }

  @Test("speaker turns parse a labelled transcript, and refuse prose")
  func speakerTurnParsing() {
    #expect(
      SpeakerTurn.parse("Speaker A: Hi.\n\nSpeaker UNKNOWN: Hm.\n\nSpeaker ?: Who?") == [
        SpeakerTurn(speaker: "A", text: "Hi."), SpeakerTurn(speaker: "UNKNOWN", text: "Hm."),
        SpeakerTurn(speaker: nil, text: "Who?"),
      ])
    #expect(SpeakerTurn.parse("Speaker A: Hi.\n\nJust prose.").isEmpty)
    #expect(SpeakerTurn.parse("Plain words.").isEmpty)
  }

  @Test("live turns come out structured, grouped by speaker, and match the saved text")
  func liveSpeakerTurns() {
    var live = LiveTranscript()
    live.apply(RealtimeTurn(order: 0, transcript: "Hi.", isFinal: true, speaker: "A"))
    live.apply(RealtimeTurn(order: 1, transcript: "Ready?", isFinal: true, speaker: "A"))
    live.apply(RealtimeTurn(order: 2, transcript: "Yes.", isFinal: true, speaker: "B"))
    #expect(
      live.speakerTurns == [SpeakerTurn(speaker: "A", text: "Hi. Ready?"), SpeakerTurn(speaker: "B", text: "Yes.")])
    #expect(SpeakerTurn.parse(live.text) == live.speakerTurns)
  }

  @Test("a re-sent final replaces the last settled turn rather than adding one")
  func finalResend() {
    var live = LiveTranscript()
    live.apply(RealtimeTurn(order: 0, transcript: "hello", isFinal: true, speaker: nil))
    live.apply(RealtimeTurn(order: 0, transcript: "Hello.", isFinal: true, speaker: nil))
    #expect(live.finals.map(\.transcript) == ["Hello."])
  }
}
