"""Application-owned capabilities for Operon.

Skills are deliberately host functions, not model tools. The model can request
only a registered descriptor; the application validates inputs, decides whether
to confirm a side effect, and validates the returned data before it enters the
answer context.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Iterable

from .models import SkillCall, SkillDescriptor, SkillResult
from .schema import validate_instance, validate_schema_definition


@dataclass(frozen=True, slots=True)
class Skill:
    descriptor: SkillDescriptor
    handler: Callable[[dict[str, Any]], SkillResult]


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

    def authorized_calls(self, calls: Iterable[SkillCall]) -> tuple[SkillCall, ...]:
        accepted: list[SkillCall] = []
        for call in calls:
            skill = self._skills.get(call.skill_id)
            if skill is None:
                continue
            if not validate_instance(call.arguments, skill.descriptor.input_schema):
                accepted.append(call)
        return tuple(accepted)

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
