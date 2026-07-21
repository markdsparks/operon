from __future__ import annotations

import json
import unittest
from unittest.mock import patch

from operon.models import GenerationRequest
from operon.providers.openai_compatible import OpenAICompatibleProvider


class _Response:
    def __enter__(self) -> _Response:
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def read(self, *args: object) -> bytes:
        return json.dumps(
            {
                "choices": [
                    {"message": {"content": '{"answer":"ok"}'}, "finish_reason": "stop"}
                ],
                "usage": {"prompt_tokens": 10, "completion_tokens": 5},
            }
        ).encode()


class OpenAICompatibleProviderTests(unittest.TestCase):
    @patch("operon.providers.openai_compatible.urlopen", return_value=_Response())
    def test_sends_json_schema_and_parses_usage(self, mocked_urlopen: object) -> None:
        provider = OpenAICompatibleProvider(model="small-model")
        response = provider.generate(
            GenerationRequest(
                messages=({"role": "user", "content": "hello"},),
                schema={"type": "object"},
                reasoning_effort="none",
            )
        )

        self.assertEqual(response.text, '{"answer":"ok"}')
        self.assertEqual(response.prompt_tokens, 10)
        request = mocked_urlopen.call_args.args[0]  # type: ignore[attr-defined]
        payload = json.loads(request.data)
        self.assertEqual(payload["model"], "small-model")
        self.assertEqual(payload["response_format"]["type"], "json_schema")
        self.assertEqual(payload["reasoning_effort"], "none")

    @patch("operon.providers.openai_compatible.urlopen", return_value=_Response())
    def test_uses_configured_completion_token_parameter(self, mocked_urlopen: object) -> None:
        provider = OpenAICompatibleProvider(
            model="cloud-model", completion_token_parameter="max_completion_tokens"
        )
        provider.generate(
            GenerationRequest(
                messages=({"role": "user", "content": "hello"},), max_tokens=123
            )
        )

        request = mocked_urlopen.call_args.args[0]  # type: ignore[attr-defined]
        payload = json.loads(request.data)
        self.assertEqual(payload["max_completion_tokens"], 123)
        self.assertNotIn("max_tokens", payload)


if __name__ == "__main__":
    unittest.main()
