"""Operon: a local-first cognitive runtime for constrained models."""

from .grounding import LocalDocuments
from .memory import (
    MemoryAuthority,
    MemoryKind,
    MemoryRecord,
    MemoryScope,
    MemorySensitivity,
    SQLiteMemoryStore,
)
from .models import OperonResponse, Policy
from .providers.openai_compatible import OpenAICompatibleProvider
from .runtime import Operon, OperonValidationError
from .sessions import SQLiteSessionStore

__all__ = [
    "LocalDocuments",
    "MemoryAuthority",
    "MemoryKind",
    "MemoryRecord",
    "MemoryScope",
    "MemorySensitivity",
    "OpenAICompatibleProvider",
    "Operon",
    "OperonResponse",
    "OperonValidationError",
    "Policy",
    "SQLiteSessionStore",
    "SQLiteMemoryStore",
]

__version__ = "0.1.0"
