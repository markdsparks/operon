from __future__ import annotations

import json
from dataclasses import dataclass
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from operon.models import (
    GenerationRequest,
    GenerationResponse,
    ModelCapabilities,
)


class ProviderError(RuntimeError):
    pass


@dataclass(slots=True)
class OpenAICompatibleProvider:
    """Adapter for Ollama, llama-server, LM Studio, and compatible APIs."""

    model: str
    base_url: str = "http://127.0.0.1:11434/v1"
    api_key: str | None = None
    timeout_seconds: float = 60.0
    supports_structured_output: bool = True

    @property
    def capabilities(self) -> ModelCapabilities:
        return ModelCapabilities(
            structured_output=self.supports_structured_output,
            privacy="local" if self._is_local_url else "remote",
        )

    @property
    def _is_local_url(self) -> bool:
        hostname = urlparse(self.base_url).hostname
        return hostname in {"127.0.0.1", "localhost", "::1"}

    def generate(self, request: GenerationRequest) -> GenerationResponse:
        payload: dict[str, object] = {
            "model": self.model,
            "messages": list(request.messages),
            "temperature": request.temperature,
            "stream": False,
        }
        if request.max_tokens is not None:
            payload["max_tokens"] = request.max_tokens
        if request.reasoning_effort is not None:
            payload["reasoning_effort"] = request.reasoning_effort
        if request.schema is not None and self.supports_structured_output:
            payload["response_format"] = {
                "type": "json_schema",
                "json_schema": {
                    "name": "operon_result",
                    "strict": True,
                    "schema": request.schema,
                },
            }

        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        http_request = Request(
            f"{self.base_url.rstrip('/')}/chat/completions",
            data=json.dumps(payload).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urlopen(http_request, timeout=self.timeout_seconds) as response:
                body = json.load(response)
        except HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise ProviderError(f"model server returned HTTP {exc.code}: {detail}") from exc
        except URLError as exc:
            raise ProviderError(f"could not reach model server: {exc.reason}") from exc

        try:
            choice = body["choices"][0]
            usage = body.get("usage", {})
            return GenerationResponse(
                text=choice["message"]["content"],
                prompt_tokens=usage.get("prompt_tokens"),
                completion_tokens=usage.get("completion_tokens"),
                finish_reason=choice.get("finish_reason"),
            )
        except (KeyError, IndexError, TypeError) as exc:
            raise ProviderError("model server returned an unexpected response") from exc
