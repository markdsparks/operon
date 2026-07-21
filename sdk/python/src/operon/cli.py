from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Sequence

from .grounding import LocalDocuments
from .models import Policy
from .providers.openai_compatible import OpenAICompatibleProvider, ProviderError
from .runtime import Operon, OperonValidationError


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="operon",
        description="Wrap a local SLM with planning, grounding, and verification.",
    )
    parser.add_argument("query", help="The task or question to execute")
    parser.add_argument(
        "--model",
        default=os.getenv("OPERON_MODEL"),
        help="Model name (or set OPERON_MODEL)",
    )
    parser.add_argument(
        "--base-url",
        default=os.getenv("OPERON_BASE_URL", "http://127.0.0.1:11434/v1"),
        help="OpenAI-compatible API base URL",
    )
    parser.add_argument(
        "--api-key",
        default=os.getenv("OPERON_API_KEY"),
        help="API key (prefer OPERON_API_KEY)",
    )
    parser.add_argument(
        "--ground",
        action="append",
        default=[],
        metavar="PATH",
        help="File or directory of local documents; repeat as needed",
    )
    parser.add_argument(
        "--planning",
        choices=("always", "adaptive", "never"),
        default="adaptive",
    )
    parser.add_argument(
        "--allow-remote",
        action="store_true",
        help="Allow a provider URL that is not localhost",
    )
    parser.add_argument(
        "--trace",
        action="store_true",
        help="Include the execution trace in output",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Return the complete result as JSON",
    )
    parser.add_argument(
        "--output-schema",
        metavar="FILE",
        help="JSON Schema file for validated application output",
    )
    parser.add_argument(
        "--no-schema",
        action="store_true",
        help="Do not send response_format to servers without JSON-schema support",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if not args.model:
        print("operon: --model or OPERON_MODEL is required", file=sys.stderr)
        return 2

    try:
        output_schema = _load_output_schema(args.output_schema)
        provider = OpenAICompatibleProvider(
            model=args.model,
            base_url=args.base_url,
            api_key=args.api_key,
            supports_structured_output=not args.no_schema,
        )
        grounding = LocalDocuments(args.ground) if args.ground else None
        policy = Policy(local_only=not args.allow_remote, planning=args.planning)
        response = Operon(
            provider,
            grounding=grounding,
            policy=policy,
            output_schema=output_schema,
        ).run(args.query)
    except OperonValidationError as exc:
        print(f"operon: {exc}", file=sys.stderr)
        if args.trace:
            print(
                "operon: rejected candidate: " + json.dumps(exc.candidate),
                file=sys.stderr,
            )
            for event in exc.trace.events:
                print(
                    f"  {event.elapsed_ms:8.2f} ms  {event.stage.value:9} {event.message}",
                    file=sys.stderr,
                )
        return 1
    except (ProviderError, RuntimeError, ValueError) as exc:
        print(f"operon: {exc}", file=sys.stderr)
        return 1

    if args.json:
        payload = {
            "answer": response.answer,
            "output": response.output,
            "confidence": response.confidence,
            "sources": [
                {"id": source.id, "path": source.path, "score": source.score}
                for source in response.sources
            ],
            "plan": asdict(response.plan),
            "declared_source_ids": list(response.declared_source_ids),
            "was_repaired": response.was_repaired,
        }
        if args.trace:
            payload["trace"] = [
                {
                    "stage": event.stage.value,
                    "message": event.message,
                    "elapsed_ms": event.elapsed_ms,
                    "data": event.data,
                }
                for event in response.trace.events
            ]
        print(json.dumps(payload, indent=2))
        return 0

    print(response.answer)
    if response.output is not None:
        print("\nOutput:")
        print(json.dumps(response.output, indent=2))
    if response.sources:
        print("\nSources:")
        for source in response.sources:
            print(f"  [{source.id}] {source.path}")
    if args.trace:
        print("\nTrace:")
        for event in response.trace.events:
            print(f"  {event.elapsed_ms:8.2f} ms  {event.stage.value:9} {event.message}")
    return 0


def _load_output_schema(path: str | None) -> dict[str, object] | None:
    if path is None:
        return None
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("output schema must be a JSON object")
    return value


if __name__ == "__main__":
    raise SystemExit(main())
