import Foundation

// The release/microphone-stop half of the session lives separately from the
// pipeline that consumes the completed recording.
extension DictationSession {
  public func release() async {
    await enqueue { await self.performRelease() }
  }

  func performRelease() async {
    guard phase == .recording || phase == .longMode else { return }
    cancelAutoRelease()
    setPhase(.transcribing)
    let recordedBytes: Int
    do {
      recordedBytes = try await mic.stop()
    } catch {
      if cancelWonRelease() { return }
      let captureError = BlurtError.audioCaptureFailed(underlying: error)
      if vibePipeline != nil {
        routingSession?.cancel()
        await localAudioWriter?.cancelAndDelete()
        if var record = currentRecord {
          record.audioRelativePath = nil
          currentRecord = record
        }
        await failVibeRecord(captureError)
      } else {
        setPhase(.failed(captureError))
      }
      return
    }
    if cancelWonRelease() { return }
    recordedByteCount = recordedBytes
    guard recordedBytes >= SyncSTTLimits.minPCMBytes else {
      await discardVibeRecording()
      setPhase(.idle)
      return
    }
    pipelineTask = Task { [weak self] in await self?.runTranscribeInject() }
  }

  func cancelWonRelease() -> Bool {
    consumeCancelRequest() || phase != .transcribing
  }

  func consumeCancelRequest() -> Bool {
    guard cancelRequested else { return false }
    cancelRequested = false
    setPhase(.cancelled)
    return true
  }

  func stopAndCancel() async {
    cancelAutoRelease()
    // Cancel the route before capture teardown finishes its frame stream.
    cancelUpload()
    do {
      try await mic.cancelCapture()
    } catch {
      seams.logFailure(.audioCaptureFailed(underlying: error), capturedContext)
    }
    await discardVibeRecording()
    setPhase(.cancelled)
  }
}
