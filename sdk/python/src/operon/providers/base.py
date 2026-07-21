from __future__ import annotations

from typing import Protocol

from operon.models import GenerationRequest, GenerationResponse, ModelCapabilities


class InferenceProvider(Protocol):
    """The narrow boundary every local or remote model adapter implements."""

    @property
    def capabilities(self) -> ModelCapabilities: ...

    def generate(self, request: GenerationRequest) -> GenerationResponse: ...
