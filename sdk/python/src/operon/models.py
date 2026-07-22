from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from time import monotonic
from typing import Any


class Stage(str, Enum):
    CLASSIFY = "classify"
    SKILL = "skill"
    GROUND = "ground"
    GENERATE = "generate"
    VALIDATE = "validate"
    REPAIR = "repair"


@dataclass(frozen=True, slots=True)
class Policy:
    """Resource and behavior limits for a single Operon runtime."""

    local_only: bool = True
    planning: str = "adaptive"
    verification: str = "adaptive"
    max_repair_attempts: int = 1
    max_context_chars: int = 12_000
    max_sources: int = 5
    request_timeout_seconds: float = 60.0
    max_replans: int = 2
    require_skill_or_clarification: bool = False

    def __post_init__(self) -> None:
        if self.planning not in {"always", "adaptive", "never"}:
            raise ValueError("planning must be always, adaptive, or never")
        if self.verification not in {"always", "adaptive", "never"}:
            raise ValueError("verification must be always, adaptive, or never")
        if self.max_repair_attempts < 0:
            raise ValueError("max_repair_attempts cannot be negative")
        if self.max_context_chars < 1:
            raise ValueError("max_context_chars must be positive")
        if self.max_replans < 0:
            raise ValueError("max_replans cannot be negative")


@dataclass(frozen=True, slots=True)
class ModelCapabilities:
    structured_output: bool = False
    tools: bool = False
    vision: bool = False
    streaming: bool = False
    context_window: int | None = None
    privacy: str = "local"


@dataclass(frozen=True, slots=True)
class GenerationRequest:
    messages: tuple[dict[str, str], ...]
    schema: dict[str, Any] | None = None
    temperature: float = 0.1
    max_tokens: int | None = None
    reasoning_effort: str | None = None


@dataclass(frozen=True, slots=True)
class GenerationResponse:
    text: str
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    finish_reason: str | None = None


@dataclass(frozen=True, slots=True)
class Source:
    id: str
    path: str
    text: str
    score: float


@dataclass(frozen=True, slots=True)
class SkillDescriptor:
    id: str
    description: str
    input_schema: dict[str, Any]
    output_schema: dict[str, Any]
    requires_user_confirmation: bool = False


@dataclass(frozen=True, slots=True)
class SkillCall:
    skill_id: str
    arguments: dict[str, Any]


@dataclass(frozen=True, slots=True)
class SkillResult:
    output: Any
    sources: tuple[Source, ...] = ()
    artifacts: tuple[SessionArtifact, ...] = ()


@dataclass(frozen=True, slots=True)
class SessionArtifact:
    id: str
    kind: str
    summary: str
    value: Any
    turn_id: str | None = None
    expires_at: str | None = None


@dataclass(frozen=True, slots=True)
class Clarification:
    prompt: str
    missing_fields: tuple[str, ...] = ()
    skill_id: str | None = None


@dataclass(frozen=True, slots=True)
class Plan:
    intent: str
    subquestions: tuple[str, ...]
    needs_grounding: bool
    answer_requirements: tuple[str, ...] = ()
    skill_calls: tuple[SkillCall, ...] = ()
    clarification: Clarification | None = None


@dataclass(slots=True)
class TraceEvent:
    stage: Stage
    message: str
    data: dict[str, Any] = field(default_factory=dict)
    elapsed_ms: float = 0.0


@dataclass(slots=True)
class ExecutionTrace:
    _started: float = field(default_factory=monotonic, repr=False)
    events: list[TraceEvent] = field(default_factory=list)

    def add(self, stage: Stage, message: str, **data: Any) -> None:
        self.events.append(
            TraceEvent(
                stage=stage,
                message=message,
                data=data,
                elapsed_ms=round((monotonic() - self._started) * 1000, 2),
            )
        )


@dataclass(frozen=True, slots=True)
class OperonResponse:
    answer: str
    output: Any | None
    sources: tuple[Source, ...]
    confidence: float | None
    plan: Plan
    trace: ExecutionTrace
    declared_source_ids: tuple[str, ...] = ()
    was_repaired: bool = False
    clarification: Clarification | None = None
