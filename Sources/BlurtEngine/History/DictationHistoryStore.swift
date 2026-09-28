import CoreData
import Foundation

public protocol DictationHistoryStore: Sendable {
  func upsert(_ record: DictationRecord) async throws
  func record(id: UUID) async throws -> DictationRecord?
  func newest() async throws -> DictationRecord?
  func search(_ query: String) async throws -> [DictationRecord]
  func all() async throws -> [DictationRecord]
  func delete(id: UUID) async throws
  func deleteAll() async throws
}

public actor CoreDataDictationHistoryStore: DictationHistoryStore {
  private let container: NSPersistentContainer

  public init(storeURL: URL? = nil, inMemory: Bool = false) async throws {
    let container = NSPersistentContainer(
      name: "VibeDictateHistory", managedObjectModel: Self.makeModel())
    let description = NSPersistentStoreDescription()
    if inMemory {
      description.type = NSInMemoryStoreType
      // Concurrent in-memory containers must not share Core Data's default URL.
      description.url = URL(fileURLWithPath: "/dev/null/\(UUID().uuidString)")
    } else if let storeURL {
      description.url = storeURL
      description.type = NSSQLiteStoreType
    } else {
      let support =
        try FileManager.default.url(
          for: .applicationSupportDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true
        )
        .appending(path: "VibeDictate", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
      description.url = support.appending(path: "History.sqlite")
      description.type = NSSQLiteStoreType
    }
    description.shouldMigrateStoreAutomatically = true
    description.shouldInferMappingModelAutomatically = true
    container.persistentStoreDescriptions = [description]
    self.container = container
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      container.loadPersistentStores { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
    container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
  }

  public func upsert(_ record: DictationRecord) async throws {
    let context = container.newBackgroundContext()
    try await context.perform {
      let request = ManagedDictationRecord.fetchRequest()
      request.predicate = NSPredicate(format: "id == %@", record.id as CVarArg)
      request.fetchLimit = 1
      let object = try context.fetch(request).first ?? ManagedDictationRecord(context: context)
      object.apply(record)
      try context.save()
    }
  }

  public func record(id: UUID) async throws -> DictationRecord? {
    let context = container.newBackgroundContext()
    return try await context.perform {
      let request = ManagedDictationRecord.fetchRequest()
      request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
      request.fetchLimit = 1
      return try context.fetch(request).first?.value
    }
  }

  public func newest() async throws -> DictationRecord? {
    try await fetch(query: nil, limit: 1).first
  }

  public func search(_ query: String) async throws -> [DictationRecord] {
    try await fetch(query: query.trimmedNonEmpty(), limit: nil)
  }

  public func all() async throws -> [DictationRecord] {
    try await fetch(query: nil, limit: nil)
  }

  public func delete(id: UUID) async throws {
    let context = container.newBackgroundContext()
    try await context.perform {
      let request = ManagedDictationRecord.fetchRequest()
      request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
      for object in try context.fetch(request) { context.delete(object) }
      try context.save()
    }
  }

  public func deleteAll() async throws {
    let context = container.newBackgroundContext()
    try await context.perform {
      for object in try context.fetch(ManagedDictationRecord.fetchRequest()) {
        context.delete(object)
      }
      try context.save()
    }
  }

  private func fetch(query: String?, limit: Int?) async throws -> [DictationRecord] {
    let context = container.newBackgroundContext()
    return try await context.perform {
      let request = ManagedDictationRecord.fetchRequest()
      request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
      if let query {
        request.predicate = NSPredicate(
          format: "rawTranscript CONTAINS[cd] %@ OR normalizedTranscript CONTAINS[cd] %@",
          query, query)
      }
      if let limit { request.fetchLimit = limit }
      return try context.fetch(request).map(\.value)
    }
  }

  private static func makeModel() -> NSManagedObjectModel {
    let model = NSManagedObjectModel()
    let entity = NSEntityDescription()
    entity.name = "DictationRecord"
    entity.managedObjectClassName = NSStringFromClass(ManagedDictationRecord.self)

    func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
      let value = NSAttributeDescription()
      value.name = name
      value.attributeType = type
      value.isOptional = optional
      return value
    }
    entity.properties = [
      attribute("id", .UUIDAttributeType),
      attribute("generation", .integer64AttributeType),
      attribute("createdAt", .dateAttributeType),
      attribute("finishedAt", .dateAttributeType, optional: true),
      attribute("durationMs", .integer64AttributeType),
      attribute("status", .stringAttributeType),
      attribute("pipelineMode", .stringAttributeType),
      attribute("rawTranscript", .stringAttributeType),
      attribute("assemblyCleanTranscript", .stringAttributeType, optional: true),
      attribute("normalizedTranscript", .stringAttributeType, optional: true),
      attribute("targetBundleIdentifier", .stringAttributeType, optional: true),
      attribute("targetAppName", .stringAttributeType, optional: true),
      attribute("targetWindowTitle", .stringAttributeType, optional: true),
      attribute("audioRelativePath", .stringAttributeType, optional: true),
      attribute("sttProvider", .stringAttributeType),
      attribute("normalizationProvider", .stringAttributeType, optional: true),
      attribute("normalizationModel", .stringAttributeType, optional: true),
      attribute("insertionStatus", .stringAttributeType),
      attribute("errorMessage", .stringAttributeType, optional: true),
    ]
    entity.uniquenessConstraints = [["id"]]
    model.entities = [entity]
    return model
  }
}

@objc(ManagedDictationRecord)
private final class ManagedDictationRecord: NSManagedObject {
  @NSManaged var id: UUID
  @NSManaged var generation: Int64
  @NSManaged var createdAt: Date
  @NSManaged var finishedAt: Date?
  @NSManaged var durationMs: Int64
  @NSManaged var status: String
  @NSManaged var pipelineMode: String
  @NSManaged var rawTranscript: String
  @NSManaged var assemblyCleanTranscript: String?
  @NSManaged var normalizedTranscript: String?
  @NSManaged var targetBundleIdentifier: String?
  @NSManaged var targetAppName: String?
  @NSManaged var targetWindowTitle: String?
  @NSManaged var audioRelativePath: String?
  @NSManaged var sttProvider: String
  @NSManaged var normalizationProvider: String?
  @NSManaged var normalizationModel: String?
  @NSManaged var insertionStatus: String
  @NSManaged var errorMessage: String?

  static func fetchRequest() -> NSFetchRequest<ManagedDictationRecord> {
    NSFetchRequest(entityName: "DictationRecord")
  }

  func apply(_ value: DictationRecord) {
    id = value.id
    generation = Int64(value.generation)
    createdAt = value.createdAt
    finishedAt = value.finishedAt
    durationMs = value.durationMs
    status = value.status.rawValue
    pipelineMode = value.pipelineMode.rawValue
    rawTranscript = value.rawTranscript
    assemblyCleanTranscript = value.assemblyCleanTranscript
    normalizedTranscript = value.normalizedTranscript
    targetBundleIdentifier = value.targetBundleIdentifier
    targetAppName = value.targetAppName
    targetWindowTitle = value.targetWindowTitle
    audioRelativePath = value.audioRelativePath
    sttProvider = value.sttProvider
    normalizationProvider = value.normalizationProvider
    normalizationModel = value.normalizationModel
    insertionStatus = value.insertionStatus.rawValue
    errorMessage = value.errorMessage
  }

  var value: DictationRecord {
    let job = DictationJob(
      id: id, generation: UInt64(generation), createdAt: createdAt,
      targetBundleIdentifier: targetBundleIdentifier, targetAppName: targetAppName,
      targetWindowTitle: targetWindowTitle)
    var record = DictationRecord(
      job: job, durationMs: durationMs,
      status: DictationRecordStatus(rawValue: status) ?? .failed,
      pipelineMode: DictationPipelineMode(rawValue: pipelineMode) ?? .short,
      rawTranscript: rawTranscript,
      assemblyCleanTranscript: assemblyCleanTranscript,
      normalizedTranscript: normalizedTranscript, audioRelativePath: audioRelativePath,
      sttProvider: sttProvider, normalizationProvider: normalizationProvider,
      normalizationModel: normalizationModel,
      insertionStatus: DictationInsertionStatus(rawValue: insertionStatus) ?? .failed,
      errorMessage: errorMessage)
    record.finishedAt = finishedAt
    return record
  }
}
