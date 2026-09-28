import AppKit
import BlurtEngine

extension HistoryModel {
  var injector: KeyInjector { historyInjector }
  var sound: NSSound? {
    get { playingSound }
    set { playingSound = newValue }
  }

  func insertLast() {
    Task {
      guard let store = historyStore else { return }
      do {
        let newest = try await store.newest()
        switch LatestDictationDecision.resolve(records: newest.map { [$0] } ?? []) {
        case .insert(let recordID, let text):
          try await injector.insert(recordID: recordID, text: text)
          message = "Последняя диктовка вставлена."
        case .processing: message = "Последняя диктовка ещё обрабатывается."
        case .failed: message = "Последняя диктовка завершилась ошибкой."
        case .noHistory: message = "История пока пуста."
        case .readyWithoutText: message = "В последней диктовке нет готового текста."
        }
      } catch { message = error.localizedDescription }
    }
  }

  func insert(_ record: DictationRecord) {
    guard let text = record.preferredText else { return }
    Task {
      do {
        try await injector.insert(recordID: record.id, text: text)
        message = "Текст вставлен."
      } catch { message = error.localizedDescription }
    }
  }

  func copy(_ record: DictationRecord) {
    guard let text = record.preferredText else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    message = "Текст скопирован."
  }

  func play(_ record: DictationRecord) {
    guard let path = record.audioRelativePath,
      let url = try? Self.applicationSupportURL().appending(path: path)
    else { return }
    sound = NSSound(contentsOf: url, byReference: true)
    sound?.play()
  }

  func delete(_ record: DictationRecord) {
    Task {
      do {
        if let path = record.audioRelativePath,
          let url = try? Self.applicationSupportURL().appending(path: path)
        {
          try? FileManager.default.removeItem(at: url)
        }
        try await historyStore?.delete(id: record.id)
        selection = nil
        await load()
      } catch { message = error.localizedDescription }
    }
  }

  func clearHistory() {
    Task {
      do {
        for record in try await historyStore?.all() ?? [] {
          if let path = record.audioRelativePath,
            let url = try? Self.applicationSupportURL().appending(path: path)
          {
            try? FileManager.default.removeItem(at: url)
          }
        }
        try await historyStore?.deleteAll()
        activeRecord = nil
        selection = nil
        await load()
        message = "История очищена."
      } catch { message = error.localizedDescription }
    }
  }
}
