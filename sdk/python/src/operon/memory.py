"""Typed, application-authorized durable memory for Operon hosts.

Records are created by application code. This module deliberately has no model
write path: an LLM may consume retrieved records as historical context, but it
does not gain authority to create, update, or delete them.
"""

from __future__ import annotations

import json
import re
import sqlite3
import uuid
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Protocol


class MemoryKind(str, Enum):
    FACT = "fact"
    PREFERENCE = "preference"
    DECISION = "decision"
    EPISODE = "episode"


class MemoryAuthority(str, Enum):
    APPLICATION_VERIFIED = "application_verified"
    USER_CONFIRMED = "user_confirmed"
    USER_STATED = "user_stated"
    MODEL_INFERRED = "model_inferred"
    IMPORTED_UNTRUSTED = "imported_untrusted"


class MemorySensitivity(str, Enum):
    PRIVATE = "private"
    INTERNAL = "internal"
    PUBLIC = "public"


class MemoryStatus(str, Enum):
    ACTIVE = "active"
    SUPERSEDED = "superseded"
    TOMBSTONED = "tombstoned"


@dataclass(frozen=True, slots=True)
class MemoryScope:
    """The authorization boundary applied before relevance ranking."""

    namespace: str
    subject: str | None = None
    allowed_sensitivities: tuple[MemorySensitivity, ...] = (
        MemorySensitivity.PRIVATE,
        MemorySensitivity.INTERNAL,
    )

    def __post_init__(self) -> None:
        if not self.namespace.strip():
            raise ValueError("memory namespace cannot be empty")
        if not self.allowed_sensitivities:
            raise ValueError("memory scope needs at least one allowed sensitivity")


@dataclass(frozen=True, slots=True)
class MemoryRecord:
    id: str
    namespace: str
    subject: str | None
    kind: MemoryKind
    content: str
    authority: MemoryAuthority
    sensitivity: MemorySensitivity = MemorySensitivity.PRIVATE
    confidence: float | None = None
    source_ids: tuple[str, ...] = ()
    occurred_at: str | None = None
    observed_at: str | None = None
    valid_from: str | None = None
    valid_until: str | None = None
    supersedes: str | None = None
    status: MemoryStatus = MemoryStatus.ACTIVE
    created_by: str = "application"
    schema_version: int = 1

    @classmethod
    def create(
        cls,
        *,
        namespace: str,
        kind: MemoryKind,
        content: str,
        authority: MemoryAuthority,
        subject: str | None = None,
        **kwargs: object,
    ) -> MemoryRecord:
        return cls(
            id=str(uuid.uuid4()),
            namespace=namespace,
            subject=subject,
            kind=kind,
            content=content,
            authority=authority,
            **kwargs,
        )


@dataclass(frozen=True, slots=True)
class MemoryContext:
    scope: MemoryScope
    records: tuple[MemoryRecord, ...]
    text: str
    omitted_record_count: int


class MemoryStore(Protocol):
    def put(self, record: MemoryRecord) -> MemoryRecord: ...

    def search(
        self, query: str, scope: MemoryScope, limit: int
    ) -> tuple[MemoryRecord, ...]: ...

    def context(
        self, query: str, scope: MemoryScope, limit: int, maximum_characters: int
    ) -> MemoryContext: ...

    def tombstone(self, memory_id: str) -> bool: ...

    def export(self, scope: MemoryScope) -> dict[str, object]: ...

    def delete_namespace(self, namespace: str) -> int: ...


class SQLiteMemoryStore:
    """A local SQLite/FTS5 store for explicit, typed durable memory records."""

    def __init__(self, path: str | Path) -> None:
        self.path = str(path)
        if self.path == ":memory:":
            raise ValueError("SQLiteMemoryStore requires a file path, not :memory:")
        Path(self.path).expanduser().parent.mkdir(parents=True, exist_ok=True)
        self._initialize()

    def put(self, record: MemoryRecord) -> MemoryRecord:
        record = _validated_record(record)
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            if record.supersedes:
                connection.execute(
                    """
                    UPDATE operon_memory
                    SET status = ?
                    WHERE id = ? AND namespace = ? AND status = ?
                    """,
                    (
                        MemoryStatus.SUPERSEDED.value,
                        record.supersedes,
                        record.namespace,
                        MemoryStatus.ACTIVE.value,
                    ),
                )
                connection.execute(
                    "DELETE FROM operon_memory_fts WHERE memory_id = ?",
                    (record.supersedes,),
                )
            connection.execute(
                """
                INSERT INTO operon_memory(
                    id, namespace, subject, kind, content, authority, sensitivity,
                    confidence, source_ids, occurred_at, observed_at, valid_from,
                    valid_until, supersedes, status, created_by, schema_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                _record_row(record),
            )
            connection.execute(
                "INSERT INTO operon_memory_fts(memory_id, search_text) VALUES (?, ?)",
                (record.id, _search_text(record)),
            )
        return record

    def search(
        self, query: str, scope: MemoryScope, limit: int
    ) -> tuple[MemoryRecord, ...]:
        if limit < 1:
            raise ValueError("memory search limit must be positive")
        match = _fts_query(query)
        if not match:
            return ()
        filters = [
            "m.namespace = ?",
            "m.status = ?",
            "(m.valid_from IS NULL OR m.valid_from <= ?)",
            "(m.valid_until IS NULL OR m.valid_until > ?)",
        ]
        values: list[object] = [
            scope.namespace,
            MemoryStatus.ACTIVE.value,
            _now(),
            _now(),
        ]
        if scope.subject is not None:
            filters.append("m.subject = ?")
            values.append(scope.subject)
        placeholders = ", ".join("?" for _ in scope.allowed_sensitivities)
        filters.append(f"m.sensitivity IN ({placeholders})")
        values.extend(item.value for item in scope.allowed_sensitivities)
        values.extend([match, limit])
        sql = f"""
            SELECT m.id, m.namespace, m.subject, m.kind, m.content, m.authority,
                   m.sensitivity, m.confidence, m.source_ids, m.occurred_at,
                   m.observed_at, m.valid_from, m.valid_until, m.supersedes,
                   m.status, m.created_by, m.schema_version
            FROM operon_memory_fts
            JOIN operon_memory AS m ON m.id = operon_memory_fts.memory_id
            WHERE {' AND '.join(filters)}
              AND operon_memory_fts.search_text MATCH ?
            ORDER BY bm25(operon_memory_fts), m.observed_at DESC
            LIMIT ?
        """
        with self._connect() as connection:
            rows = connection.execute(sql, values).fetchall()
        return tuple(_row_record(row) for row in rows)

    def context(
        self, query: str, scope: MemoryScope, limit: int, maximum_characters: int
    ) -> MemoryContext:
        if maximum_characters < 1:
            raise ValueError("maximum_characters must be positive")
        records = self.search(query, scope, limit)
        sections: list[str] = []
        remaining = maximum_characters
        for record in records:
            text = _render(record)
            if len(text) > remaining:
                break
            sections.append(text)
            remaining -= len(text) + 2
        included = records[: len(sections)]
        return MemoryContext(
            scope=scope,
            records=included,
            text="\n\n".join(sections),
            omitted_record_count=len(records) - len(included),
        )

    def tombstone(self, memory_id: str) -> bool:
        memory_id = memory_id.strip()
        if not memory_id:
            raise ValueError("memory_id cannot be empty")
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            updated = connection.execute(
                "UPDATE operon_memory SET status = ? WHERE id = ? AND status != ?",
                (MemoryStatus.TOMBSTONED.value, memory_id, MemoryStatus.TOMBSTONED.value),
            ).rowcount
            connection.execute(
                "DELETE FROM operon_memory_fts WHERE memory_id = ?", (memory_id,)
            )
        return bool(updated)

    def export(self, scope: MemoryScope) -> dict[str, object]:
        filters = ["namespace = ?"]
        values: list[object] = [scope.namespace]
        if scope.subject is not None:
            filters.append("subject = ?")
            values.append(scope.subject)
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT id, namespace, subject, kind, content, authority, sensitivity, "
                "confidence, source_ids, occurred_at, observed_at, valid_from, valid_until, "
                "supersedes, status, created_by, schema_version FROM operon_memory WHERE "
                + " AND ".join(filters)
                + " ORDER BY observed_at ASC, id ASC",
                values,
            ).fetchall()
        return {
            "schema_version": 1,
            "scope": {"namespace": scope.namespace, "subject": scope.subject},
            "records": [_record_export(_row_record(row)) for row in rows],
        }

    def delete_namespace(self, namespace: str) -> int:
        namespace = namespace.strip()
        if not namespace:
            raise ValueError("memory namespace cannot be empty")
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            ids = connection.execute(
                "SELECT id FROM operon_memory WHERE namespace = ?", (namespace,)
            ).fetchall()
            connection.executemany(
                "DELETE FROM operon_memory_fts WHERE memory_id = ?", ids
            )
            deleted = connection.execute(
                "DELETE FROM operon_memory WHERE namespace = ?", (namespace,)
            ).rowcount
        return deleted

    def _initialize(self) -> None:
        with self._connect() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS operon_memory (
                    id TEXT PRIMARY KEY,
                    namespace TEXT NOT NULL,
                    subject TEXT,
                    kind TEXT NOT NULL,
                    content TEXT NOT NULL,
                    authority TEXT NOT NULL,
                    sensitivity TEXT NOT NULL,
                    confidence REAL,
                    source_ids TEXT NOT NULL,
                    occurred_at TEXT,
                    observed_at TEXT NOT NULL,
                    valid_from TEXT,
                    valid_until TEXT,
                    supersedes TEXT,
                    status TEXT NOT NULL,
                    created_by TEXT NOT NULL,
                    schema_version INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS operon_memory_by_scope
                    ON operon_memory(namespace, subject, status, observed_at);
                CREATE VIRTUAL TABLE IF NOT EXISTS operon_memory_fts USING fts5(
                    memory_id UNINDEXED,
                    search_text
                );
                """
            )

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self.path)


def _validated_record(record: MemoryRecord) -> MemoryRecord:
    if not record.id.strip():
        raise ValueError("memory id cannot be empty")
    if not record.namespace.strip():
        raise ValueError("memory namespace cannot be empty")
    if not record.content.strip():
        raise ValueError("memory content cannot be empty")
    if record.confidence is not None and not 0 <= record.confidence <= 1:
        raise ValueError("memory confidence must be between 0 and 1")
    if record.valid_from and record.valid_until and record.valid_from >= record.valid_until:
        raise ValueError("memory valid_until must be later than valid_from")
    return replace(record, observed_at=record.observed_at or _now())


def _record_row(record: MemoryRecord) -> tuple[object, ...]:
    return (
        record.id,
        record.namespace,
        record.subject,
        record.kind.value,
        record.content,
        record.authority.value,
        record.sensitivity.value,
        record.confidence,
        json.dumps(record.source_ids),
        record.occurred_at,
        record.observed_at,
        record.valid_from,
        record.valid_until,
        record.supersedes,
        record.status.value,
        record.created_by,
        record.schema_version,
    )


def _row_record(row: tuple[object, ...]) -> MemoryRecord:
    return MemoryRecord(
        id=str(row[0]),
        namespace=str(row[1]),
        subject=row[2] if isinstance(row[2], str) else None,
        kind=MemoryKind(str(row[3])),
        content=str(row[4]),
        authority=MemoryAuthority(str(row[5])),
        sensitivity=MemorySensitivity(str(row[6])),
        confidence=float(row[7]) if row[7] is not None else None,
        source_ids=tuple(json.loads(str(row[8]))),
        occurred_at=row[9] if isinstance(row[9], str) else None,
        observed_at=row[10] if isinstance(row[10], str) else None,
        valid_from=row[11] if isinstance(row[11], str) else None,
        valid_until=row[12] if isinstance(row[12], str) else None,
        supersedes=row[13] if isinstance(row[13], str) else None,
        status=MemoryStatus(str(row[14])),
        created_by=str(row[15]),
        schema_version=int(row[16]),
    )


def _record_export(record: MemoryRecord) -> dict[str, object]:
    return {
        "id": record.id,
        "namespace": record.namespace,
        "subject": record.subject,
        "kind": record.kind.value,
        "content": record.content,
        "authority": record.authority.value,
        "sensitivity": record.sensitivity.value,
        "confidence": record.confidence,
        "source_ids": list(record.source_ids),
        "occurred_at": record.occurred_at,
        "observed_at": record.observed_at,
        "valid_from": record.valid_from,
        "valid_until": record.valid_until,
        "supersedes": record.supersedes,
        "status": record.status.value,
        "created_by": record.created_by,
        "schema_version": record.schema_version,
    }


def _search_text(record: MemoryRecord) -> str:
    return " ".join(
        part for part in (record.kind.value, record.content, record.subject or "") if part
    )


def _fts_query(query: str) -> str:
    terms = re.findall(r"[\w]+", query.lower(), flags=re.UNICODE)
    return " OR ".join(f'"{term}"' for term in terms)


def _render(record: MemoryRecord) -> str:
    subject = f" subject={record.subject}" if record.subject else ""
    time = f" observed_at={record.observed_at}" if record.observed_at else ""
    return (
        f"[M:{record.id}] kind={record.kind.value} authority={record.authority.value}"
        f" sensitivity={record.sensitivity.value}{subject}{time}\n{record.content}"
    )


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()
