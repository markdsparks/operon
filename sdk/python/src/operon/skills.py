"""Application-owned capabilities for Operon.

Skills are deliberately host functions, not model tools. The model can request
only a registered descriptor; the application validates inputs, decides whether
to confirm a side effect, and validates the returned data before it enters the
answer context.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Iterable

from .models import Clarification, SessionArtifact, SkillCall, SkillDescriptor, SkillResult
from .schema import validate_instance, validate_schema_definition


@dataclass(frozen=True, slots=True)
class Skill:
    descriptor: SkillDescriptor
    handler: Callable[[dict[str, Any]], SkillResult]
    prepare: Callable[[dict[str, Any], tuple[SessionArtifact, ...]], "SkillPreparation"] | None = None


@dataclass(frozen=True, slots=True)
class SkillPreparation:
    kind: str
    arguments: dict[str, Any] | None = None
    clarification: Clarification | None = None
    reason: str | None = None

    @classmethod
    def ready(cls, arguments: dict[str, Any]) -> "SkillPreparation":
        return cls("ready", arguments=arguments)

    @classmethod
    def needs_input(cls, prompt: str, *, missing_fields: tuple[str, ...] = (), skill_id: str | None = None) -> "SkillPreparation":
        return cls("needs_input", clarification=Clarification(prompt, missing_fields, skill_id))

    @classmethod
    def rejected(cls, reason: str) -> "SkillPreparation":
        return cls("rejected", reason=reason)

    @classmethod
    def unavailable(cls, reason: str) -> "SkillPreparation":
        return cls("unavailable", reason=reason)


class SkillRegistry:
    """A finite, application-authorized set of callable capabilities."""

    def __init__(
        self,
        skills: Iterable[Skill] = (),
        *,
        confirm: Callable[[SkillDescriptor, dict[str, Any]], bool] | None = None,
    ) -> None:
        self._skills: dict[str, Skill] = {}
        self._confirm = confirm
        for skill in skills:
            descriptor = skill.descriptor
            if not descriptor.id.strip() or descriptor.id in self._skills:
                raise ValueError(f"invalid or duplicate skill id: {descriptor.id!r}")
            errors = validate_schema_definition(descriptor.input_schema)
            errors += validate_schema_definition(descriptor.output_schema)
            if errors:
                raise ValueError("; ".join(errors))
            self._skills[descriptor.id] = skill

    @property
    def descriptors(self) -> tuple[SkillDescriptor, ...]:
        return tuple(skill.descriptor for skill in self._skills.values())

    def known_calls(self, calls: Iterable[SkillCall]) -> tuple[SkillCall, ...]:
        accepted: list[SkillCall] = []
        for call in calls:
            skill = self._skills.get(call.skill_id)
            if skill is None:
                continue
            accepted.append(call)
        return tuple(accepted)

    def prepare(self, call: SkillCall, artifacts: tuple[SessionArtifact, ...]) -> SkillPreparation:
        skill = self._skills.get(call.skill_id)
        if skill is None:
            return SkillPreparation("rejected", reason=f"skill is not registered: {call.skill_id}")
        prepared = skill.prepare(call.arguments, artifacts) if skill.prepare else SkillPreparation.ready(call.arguments)
        if prepared.kind != "ready":
            return prepared
        if prepared.arguments is None:
            return SkillPreparation("rejected", reason="prepared skill call has no arguments")
        errors = validate_instance(prepared.arguments, skill.descriptor.input_schema)
        if errors:
            return SkillPreparation("needs_input", clarification=Clarification(
                "I need more information before I can complete that action.", tuple(errors), call.skill_id
            ))
        return prepared

    def invoke(self, call: SkillCall) -> SkillResult:
        skill = self._skills.get(call.skill_id)
        if skill is None:
            raise ValueError(f"skill is not registered: {call.skill_id}")
        errors = validate_instance(call.arguments, skill.descriptor.input_schema)
        if errors:
            raise ValueError("invalid skill arguments: " + "; ".join(errors))
        if skill.descriptor.requires_user_confirmation:
            if self._confirm is None or not self._confirm(skill.descriptor, call.arguments):
                raise PermissionError(f"user confirmation is required for skill: {call.skill_id}")
        result = skill.handler(call.arguments)
        errors = validate_instance(result.output, skill.descriptor.output_schema)
        if errors:
            raise ValueError("invalid skill result: " + "; ".join(errors))
        return result
