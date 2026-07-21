import Foundation

public enum OperonMemoryKind: String, Codable, Sendable {
  case fact, preference, decision, episode
}

public enum OperonMemoryAuthority: String, Codable, Sendable {
  case applicationVerified = "application_verified"
  case userConfirmed = "user_confirmed"
  case userStated = "user_stated"
  case modelInferred = "model_inferred"
  case importedUntrusted = "imported_untrusted"
}

public enum OperonMemorySensitivity: String, Codable, Sendable {
  case `private`, `internal`, `public`
}

public enum OperonMemoryStatus: String, Codable, Sendable {
  case active, superseded, tombstoned
}

public struct OperonMemoryScope: Codable, Sendable, Equatable {
  public let namespace: String
  public let subject: String?
  public let allowedSensitivities: [OperonMemorySensitivity]

  public init(
    namespace: String,
    subject: String? = nil,
    allowedSensitivities: [OperonMemorySensitivity] = [.private, .internal]
  ) {
    precondition(!namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    precondition(!allowedSensitivities.isEmpty)
    self.namespace = namespace
    self.subject = subject
    self.allowedSensitivities = allowedSensitivities
  }

  enum CodingKeys: String, CodingKey {
    case namespace, subject
    case allowedSensitivities = "allowed_sensitivities"
  }
}

public struct OperonMemoryRecord: Codable, Sendable, Equatable {
  public let id: String
  public let namespace: String
  public let subject: String?
  public let kind: OperonMemoryKind
  public let content: String
  public let authority: OperonMemoryAuthority
  public let sensitivity: OperonMemorySensitivity
  public let confidence: Double?
  public let sourceIDs: [String]
  public let occurredAt: String?
  public let observedAt: String
  public let validFrom: String?
  public let validUntil: String?
  public let supersedes: String?
  public let status: OperonMemoryStatus
  public let createdBy: String
  public let schemaVersion: Int

  public init(
    id: String = UUID().uuidString.lowercased(),
    namespace: String,
    subject: String? = nil,
    kind: OperonMemoryKind,
    content: String,
    authority: OperonMemoryAuthority,
    sensitivity: OperonMemorySensitivity = .private,
    confidence: Double? = nil,
    sourceIDs: [String] = [],
    occurredAt: String? = nil,
    observedAt: String = ISO8601DateFormatter().string(from: Date()),
    validFrom: String? = nil,
    validUntil: String? = nil,
    supersedes: String? = nil,
    status: OperonMemoryStatus = .active,
    createdBy: String = "application",
    schemaVersion: Int = 1
  ) {
    precondition(!namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    precondition(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    if let confidence { precondition((0...1).contains(confidence)) }
    self.id = id
    self.namespace = namespace
    self.subject = subject
    self.kind = kind
    self.content = content
    self.authority = authority
    self.sensitivity = sensitivity
    self.confidence = confidence
    self.sourceIDs = sourceIDs
    self.occurredAt = occurredAt
    self.observedAt = observedAt
    self.validFrom = validFrom
    self.validUntil = validUntil
    self.supersedes = supersedes
    self.status = status
    self.createdBy = createdBy
    self.schemaVersion = schemaVersion
  }

  enum CodingKeys: String, CodingKey {
    case id, namespace, subject, kind, content, authority, sensitivity, confidence, status
    case sourceIDs = "source_ids"
    case occurredAt = "occurred_at"
    case observedAt = "observed_at"
    case validFrom = "valid_from"
    case validUntil = "valid_until"
    case supersedes = "supersedes"
    case createdBy = "created_by"
    case schemaVersion = "schema_version"
  }
}

public protocol OperonMemoryStore: Sendable {
  func search(
    _ query: String,
    scope: OperonMemoryScope,
    limit: Int
  ) async throws -> [OperonMemoryRecord]
}

/// Small, durable, application-owned memory store for Apple hosts.
///
/// It writes one JSON document atomically. The protocol boundary makes it
/// replaceable with a SQLite implementation without changing the core driver.
public actor FileOperonMemoryStore: OperonMemoryStore {
  private let url: URL
  private var records: [OperonMemoryRecord]

  public init(url: URL) throws {
    self.url = url
    if FileManager.default.fileExists(atPath: url.path) {
      records = try JSONDecoder().decode([OperonMemoryRecord].self, from: Data(contentsOf: url))
    } else {
      records = []
    }
  }

  @discardableResult
  public func put(_ record: OperonMemoryRecord) throws -> OperonMemoryRecord {
    if let supersedes = record.supersedes,
      let index = records.firstIndex(where: {
        $0.id == supersedes && $0.namespace == record.namespace
      })
    {
      records[index] = withStatus(records[index], .superseded)
    }
    records.removeAll { $0.id == record.id }
    records.append(record)
    try persist()
    return record
  }

  public func search(
    _ query: String,
    scope: OperonMemoryScope,
    limit: Int
  ) async throws -> [OperonMemoryRecord] {
    precondition(limit > 0)
    let now = ISO8601DateFormatter().string(from: Date())
    let terms = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    return
      records
      .filter { record in
        record.namespace == scope.namespace
          && (scope.subject == nil || record.subject == scope.subject)
          && scope.allowedSensitivities.contains(record.sensitivity)
          && record.status == .active
          && (record.validFrom == nil || record.validFrom! <= now)
          && (record.validUntil == nil || record.validUntil! > now)
      }
      .sorted {
        score($0, terms: terms) == score($1, terms: terms)
          ? $0.observedAt > $1.observedAt
          : score($0, terms: terms) > score($1, terms: terms)
      }
      .prefix(limit)
      .map { $0 }
  }

  public func tombstone(_ id: String) throws -> Bool {
    guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
    records[index] = withStatus(records[index], .tombstoned)
    try persist()
    return true
  }

  public func export(scope: OperonMemoryScope) -> [OperonMemoryRecord] {
    records.filter {
      $0.namespace == scope.namespace && (scope.subject == nil || $0.subject == scope.subject)
    }
  }

  public func delete(namespace: String) throws -> Int {
    let before = records.count
    records.removeAll { $0.namespace == namespace }
    try persist()
    return before - records.count
  }

  private func persist() throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try JSONEncoder().encode(records)
    try data.write(to: url, options: .atomic)
  }
}

private func withStatus(_ record: OperonMemoryRecord, _ status: OperonMemoryStatus)
  -> OperonMemoryRecord
{
  OperonMemoryRecord(
    id: record.id, namespace: record.namespace, subject: record.subject, kind: record.kind,
    content: record.content, authority: record.authority, sensitivity: record.sensitivity,
    confidence: record.confidence, sourceIDs: record.sourceIDs, occurredAt: record.occurredAt,
    observedAt: record.observedAt, validFrom: record.validFrom, validUntil: record.validUntil,
    supersedes: record.supersedes, status: status, createdBy: record.createdBy,
    schemaVersion: record.schemaVersion
  )
}

private func score(_ record: OperonMemoryRecord, terms: [String]) -> Int {
  let text = "\(record.kind.rawValue) \(record.subject ?? "") \(record.content)".lowercased()
  return terms.reduce(into: 0) { value, term in
    value += text.components(separatedBy: term).count - 1
  }
}
