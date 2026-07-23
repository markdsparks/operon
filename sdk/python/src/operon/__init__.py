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
from .models import Clarification, CompletionContract, OperonResponse, Policy, SessionArtifact, SkillCall, SkillDescriptor, SkillReceipt, SkillResult
from .providers.openai_compatible import OpenAICompatibleProvider
from .runtime import Operon, OperonValidationError
from .sessions import SQLiteSessionStore
from .skills import Skill, SkillPreparation, SkillRegistry

__all__ = [
    "LocalDocuments",
    "Clarification",
    "CompletionContract",
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
    "Skill",
    "SkillCall",
    "SkillDescriptor",
    "SkillReceipt",
    "SkillRegistry",
    "SkillResult",
    "SkillPreparation",
    "SessionArtifact",
]

__version__ = "0.2.0"
