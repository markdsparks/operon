import Foundation
import OperonCoreDriver
import OperonKit
import SQLite3

public struct OperonDocument: Sendable, Equatable {
  public let id: String
  public let path: String
  public let text: String

  public init(id: String, path: String, text: String) {
    self.id = id
    self.path = path
    self.text = text
  }
}

/// Incremental, application-owned FTS5 index for local grounding on Apple platforms.
public actor SQLiteOperonGroundingProvider: OperonGroundingProvider {
  private let database: SQLiteDatabase

  public init(url: URL) throws {
    database = try SQLiteDatabase(url: url)
    try database.execute(
      """
      CREATE TABLE IF NOT EXISTS operon_documents (
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL,
        text TEXT NOT NULL,
        content_hash TEXT NOT NULL
      );
      """)
    try database.execute(
      """
      CREATE VIRTUAL TABLE IF NOT EXISTS operon_documents_fts
      USING fts5(id UNINDEXED, path UNINDEXED, text, tokenize='unicode61');
      """)
  }

  /// Inserts only new or changed documents and returns the number reindexed.
  @discardableResult
  public func index(_ documents: [OperonDocument]) throws -> Int {
    try database.transaction {
      var changed = 0
      for document in documents {
        let hash = stableHash(document.text)
        let existing = try database.scalarString(
          "SELECT content_hash FROM operon_documents WHERE id = ?", [.text(document.id)])
        guard existing != hash else { continue }
        try database.run(
          """
          INSERT INTO operon_documents(id, path, text, content_hash)
          VALUES(?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            path = excluded.path,
            text = excluded.text,
            content_hash = excluded.content_hash
          """,
          [document.id, document.path, document.text, hash])
        try database.run("DELETE FROM operon_documents_fts WHERE id = ?", [document.id])
        try database.run(
          "INSERT INTO operon_documents_fts(id, path, text) VALUES(?, ?, ?)",
          [document.id, document.path, document.text])
        changed += 1
      }
      return changed
    }
  }

  public func remove(ids: [String]) throws {
    try database.transaction {
      for id in ids {
        try database.run("DELETE FROM operon_documents_fts WHERE id = ?", [id])
        try database.run("DELETE FROM operon_documents WHERE id = ?", [id])
      }
    }
  }

  public func search(_ query: String, limit: Int) async throws -> [OperonSource] {
    precondition(limit > 0)
    guard let expression = ftsExpression(query) else { return [] }
    let statement = try database.prepare(
      """
      SELECT id, path, text, bm25(operon_documents_fts)
      FROM operon_documents_fts
      WHERE operon_documents_fts MATCH ?
      ORDER BY bm25(operon_documents_fts)
      LIMIT ?
      """)
    defer { sqlite3_finalize(statement) }
    try bind(expression, to: statement, at: 1)
    sqlite3_bind_int64(statement, 2, Int64(limit))
    var sources: [OperonSource] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let rank = sqlite3_column_double(statement, 3)
      sources.append(
        OperonSource(
          id: columnText(statement, 0),
          path: columnText(statement, 1),
          text: columnText(statement, 2),
          score: 1 / (1 + abs(rank))))
    }
    return sources
  }
}

/// Indexed durable memory with scope filters applied before lexical ranking.
public actor SQLiteOperonMemoryStore: OperonMemoryStore {
  private let database: SQLiteDatabase

  public init(url: URL) throws {
    database = try SQLiteDatabase(url: url)
    try database.execute(
      """
      CREATE TABLE IF NOT EXISTS operon_memory (
        id TEXT PRIMARY KEY,
        namespace TEXT NOT NULL,
        subject TEXT,
        sensitivity TEXT NOT NULL,
        status TEXT NOT NULL,
        valid_from TEXT,
        valid_until TEXT,
        observed_at TEXT NOT NULL,
        content TEXT NOT NULL,
        record_json BLOB NOT NULL
      );
      """)
    try database.execute(
      """
      CREATE VIRTUAL TABLE IF NOT EXISTS operon_memory_fts
      USING fts5(id UNINDEXED, content, tokenize='unicode61');
      """)
  }

  @discardableResult
  public func put(_ record: OperonMemoryRecord) throws -> OperonMemoryRecord {
    try database.transaction {
      if let supersedes = record.supersedes {
        _ = try updateStatus(
          id: supersedes, namespace: record.namespace, status: .superseded)
      }
      let data = try JSONEncoder().encode(record)
      try database.run(
        """
        INSERT INTO operon_memory(
          id, namespace, subject, sensitivity, status, valid_from, valid_until,
          observed_at, content, record_json
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          namespace = excluded.namespace,
          subject = excluded.subject,
          sensitivity = excluded.sensitivity,
          status = excluded.status,
          valid_from = excluded.valid_from,
          valid_until = excluded.valid_until,
          observed_at = excluded.observed_at,
          content = excluded.content,
          record_json = excluded.record_json
        """,
        [
          record.id, record.namespace, record.subject, record.sensitivity.rawValue,
          record.status.rawValue, record.validFrom, record.validUntil, record.observedAt,
          record.content, data,
        ])
      try database.run("DELETE FROM operon_memory_fts WHERE id = ?", [record.id])
      try database.run(
        "INSERT INTO operon_memory_fts(id, content) VALUES(?, ?)",
        [record.id, record.content])
    }
    return record
  }

  public func search(
    _ query: String,
    scope: OperonMemoryScope,
    limit: Int
  ) async throws -> [OperonMemoryRecord] {
    precondition(limit > 0)
    guard let expression = ftsExpression(query) else { return [] }
    let sensitivities = scope.allowedSensitivities.map(\.rawValue)
    let placeholders = Array(repeating: "?", count: sensitivities.count).joined(separator: ",")
    var sql = """
      SELECT memory.record_json
      FROM operon_memory_fts AS search
      JOIN operon_memory AS memory ON memory.id = search.id
      WHERE operon_memory_fts MATCH ?
        AND memory.namespace = ?
        AND memory.sensitivity IN (\(placeholders))
        AND memory.status = 'active'
        AND (memory.valid_from IS NULL OR memory.valid_from <= ?)
        AND (memory.valid_until IS NULL OR memory.valid_until > ?)
      """
    if scope.subject != nil { sql += " AND memory.subject = ?" }
    sql += " ORDER BY bm25(operon_memory_fts), memory.observed_at DESC LIMIT ?"
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    var index: Int32 = 1
    try bind(expression, to: statement, at: index)
    index += 1
    try bind(scope.namespace, to: statement, at: index)
    index += 1
    for sensitivity in sensitivities {
      try bind(sensitivity, to: statement, at: index)
      index += 1
    }
    let now = ISO8601DateFormatter().string(from: Date())
    try bind(now, to: statement, at: index)
    index += 1
    try bind(now, to: statement, at: index)
    index += 1
    if let subject = scope.subject {
      try bind(subject, to: statement, at: index)
      index += 1
    }
    sqlite3_bind_int64(statement, index, Int64(limit))
    var records: [OperonMemoryRecord] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
      let count = Int(sqlite3_column_bytes(statement, 0))
      records.append(
        try JSONDecoder().decode(
          OperonMemoryRecord.self, from: Data(bytes: bytes, count: count)))
    }
    return records
  }

  public func tombstone(_ id: String) throws -> Bool {
    try updateStatus(id: id, namespace: nil, status: .tombstoned)
  }

  public func export(scope: OperonMemoryScope) throws -> [OperonMemoryRecord] {
    var sql = "SELECT record_json FROM operon_memory WHERE namespace = ?"
    var values: [SQLiteValue] = [.text(scope.namespace)]
    if let subject = scope.subject {
      sql += " AND subject = ?"
      values.append(.text(subject))
    }
    sql += " ORDER BY observed_at"
    return try database.decodeRecords(sql, values)
  }

  public func delete(namespace: String) throws -> Int {
    let ids = try database.strings(
      "SELECT id FROM operon_memory WHERE namespace = ?", [.text(namespace)])
    try database.transaction {
      for id in ids {
        try database.run("DELETE FROM operon_memory_fts WHERE id = ?", [id])
      }
      try database.run("DELETE FROM operon_memory WHERE namespace = ?", [namespace])
    }
    return ids.count
  }

  private func updateStatus(
    id: String, namespace: String?, status: OperonMemoryStatus
  ) throws -> Bool {
    var select = "SELECT record_json FROM operon_memory WHERE id = ?"
    var values: [SQLiteValue] = [.text(id)]
    if let namespace {
      select += " AND namespace = ?"
      values.append(.text(namespace))
    }
    guard let data = try database.scalarData(select, values) else { return false }
    let record = try JSONDecoder().decode(OperonMemoryRecord.self, from: data)
    let updated = copy(record, status: status)
    var update = "UPDATE operon_memory SET status = ?, record_json = ? WHERE id = ?"
    var updateValues: [SQLiteValue] = [
      .text(status.rawValue), .blob(try JSONEncoder().encode(updated)), .text(id),
    ]
    if let namespace {
      update += " AND namespace = ?"
      updateValues.append(.text(namespace))
    }
    try database.run(update, updateValues)
    return sqlite3_changes(database.handle) > 0
  }
}

private func copy(_ record: OperonMemoryRecord, status: OperonMemoryStatus)
  -> OperonMemoryRecord
{
  OperonMemoryRecord(
    id: record.id, namespace: record.namespace, subject: record.subject, kind: record.kind,
    content: record.content, authority: record.authority, sensitivity: record.sensitivity,
    confidence: record.confidence, sourceIDs: record.sourceIDs, occurredAt: record.occurredAt,
    observedAt: record.observedAt, validFrom: record.validFrom, validUntil: record.validUntil,
    supersedes: record.supersedes, status: status, createdBy: record.createdBy,
    schemaVersion: record.schemaVersion)
}

private enum SQLiteValue {
  case text(String)
  case blob(Data)
  case null
}

extension SQLiteValue {
  init(_ value: String?) { self = value.map(SQLiteValue.text) ?? .null }
}

private final class SQLiteDatabase: @unchecked Sendable {
  let handle: OpaquePointer

  init(url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var connection: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil) == SQLITE_OK, let connection
    else {
      throw sqliteError(connection, operation: "open database")
    }
    handle = connection
    try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
  }

  deinit { sqlite3_close(handle) }

  func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw sqliteError(handle, operation: "execute SQL")
    }
  }

  func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw sqliteError(handle, operation: "prepare SQL")
    }
    return statement
  }

  func run(_ sql: String, _ values: [SQLiteValue]) throws {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      try bind(value, to: statement, at: Int32(offset + 1))
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw sqliteError(handle, operation: "execute statement")
    }
  }

  func scalarString(_ sql: String, _ values: [SQLiteValue]) throws -> String? {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      try bind(value, to: statement, at: Int32(offset + 1))
    }
    return sqlite3_step(statement) == SQLITE_ROW ? columnText(statement, 0) : nil
  }

  func scalarData(_ sql: String, _ values: [SQLiteValue]) throws -> Data? {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      try bind(value, to: statement, at: Int32(offset + 1))
    }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let bytes = sqlite3_column_blob(statement, 0)
    else { return nil }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
  }

  func strings(_ sql: String, _ values: [SQLiteValue]) throws -> [String] {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      try bind(value, to: statement, at: Int32(offset + 1))
    }
    var result: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW { result.append(columnText(statement, 0)) }
    return result
  }

  func decodeRecords(_ sql: String, _ values: [SQLiteValue]) throws -> [OperonMemoryRecord] {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      try bind(value, to: statement, at: Int32(offset + 1))
    }
    var records: [OperonMemoryRecord] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
      records.append(
        try JSONDecoder().decode(
          OperonMemoryRecord.self,
          from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
    }
    return records
  }

  func transaction<Value>(_ operation: () throws -> Value) throws -> Value {
    try execute("BEGIN IMMEDIATE")
    do {
      let value = try operation()
      try execute("COMMIT")
      return value
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
  try bind(.text(value), to: statement, at: index)
}

private func bind(_ value: SQLiteValue, to statement: OpaquePointer, at index: Int32) throws {
  let status: Int32
  switch value {
  case .text(let value):
    status = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
  case .blob(let data):
    status = data.withUnsafeBytes { bytes in
      sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), sqliteTransient)
    }
  case .null:
    status = sqlite3_bind_null(statement, index)
  }
  guard status == SQLITE_OK else { throw sqliteError(nil, operation: "bind value") }
}

private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
  guard let value = sqlite3_column_text(statement, index) else { return "" }
  return String(cString: value)
}

private func sqliteError(_ handle: OpaquePointer?, operation: String) -> NSError {
  let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
  return NSError(
    domain: "OperonSQLite", code: Int(handle.map(sqlite3_errcode) ?? SQLITE_ERROR),
    userInfo: [NSLocalizedDescriptionKey: "Could not \(operation): \(message)"])
}

private func ftsExpression(_ query: String) -> String? {
  let terms = query.lowercased().split { !$0.isLetter && !$0.isNumber }
  guard !terms.isEmpty else { return nil }
  return terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
    .joined(separator: " OR ")
}

private func stableHash(_ value: String) -> String {
  var hash: UInt64 = 14_695_981_039_346_656_037
  for byte in value.utf8 {
    hash ^= UInt64(byte)
    hash &*= 1_099_511_628_211
  }
  return String(hash, radix: 16)
}

extension SQLiteValue {
  fileprivate static func from(_ value: Any?) throws -> SQLiteValue {
    switch value {
    case nil: return .null
    case let value as String: return .text(value)
    case let value as Data: return .blob(value)
    default:
      throw NSError(
        domain: "OperonSQLite", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported SQLite binding value."])
    }
  }
}

extension SQLiteDatabase {
  fileprivate func run(_ sql: String, _ values: [Any?]) throws {
    try run(sql, values.map { try SQLiteValue.from($0) })
  }
}
