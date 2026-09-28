import BlurtEngine
import SwiftUI

enum HistoryWindow { static let id = "history" }

struct HistoryWindowRoot: View {
  @ObservedObject var model: HistoryModel

  var body: some View {
    NavigationView {
      List(selection: $model.selection) {
        ForEach(model.records) { record in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(record.createdAt, style: .date)
              Text(record.createdAt, style: .time)
              Spacer()
              Text(duration(record.durationMs)).foregroundStyle(.secondary)
            }
            Text(preview(record))
              .lineLimit(2)
              .foregroundStyle(record.status == .failed ? .red : .primary)
            if record.status != .ready {
              Text(record.status == .processing ? "Обработка…" : "Ошибка")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .tag(record.id)
        }
      }
      .searchable(text: $model.searchText)
      .onChange(of: model.searchText) { _ in model.reload() }
      .frame(minWidth: 300)

      if let record = model.selectedRecord {
        detail(record)
      } else {
        Text("Выберите диктовку").foregroundStyle(.secondary)
      }
    }
    .frame(minWidth: 760, minHeight: 480)
  }

  private func detail(_ record: DictationRecord) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GroupBox("Нормализованный текст") {
          Text(record.normalizedTranscript ?? record.preferredText ?? "—")
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        GroupBox("Оригинал") {
          Text(record.rawTranscript.isEmpty ? "—" : record.rawTranscript)
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        if let clean = record.assemblyCleanTranscript {
          GroupBox("AssemblyAI clean") {
            Text(clean).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
          }
        }
        Text("\(record.pipelineMode.rawValue) · \(record.sttProvider)")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("Вставить") { model.insert(record) }
          Button("Копировать") { model.copy(record) }
          Button("Нормализовать снова") { model.normalizeAgain(record) }
          if record.status == .failed, record.audioRelativePath != nil {
            Button("Повторить распознавание") { model.retryTranscription(record) }
          }
          if record.audioRelativePath != nil { Button("Воспроизвести") { model.play(record) } }
          Spacer()
          Button("Удалить", role: .destructive) { model.delete(record) }
        }
        if let message = model.message { Text(message).font(.caption) }
      }
      .padding()
    }
  }

  private func preview(_ record: DictationRecord) -> String {
    record.preferredText ?? (record.status == .processing ? "Обработка…" : record.errorMessage ?? "Нет текста")
  }

  private func duration(_ milliseconds: Int64) -> String {
    String(format: "%.1f с", Double(milliseconds) / 1_000)
  }
}
