"""Measure grounded answer quality, literal attribution, and safe refusal."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import sys
import uuid
from collections import defaultdict
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from statistics import mean
from time import monotonic
from typing import Any, Sequence

from operon import LocalDocuments, OpenAICompatibleProvider, Operon, Policy
from operon.models import GenerationRequest, GenerationResponse, OperonResponse


CONFIGURATIONS = ("raw_full_context", "operon_citation", "operon_extractive")
PROTOCOL_VERSION = "groundbench-0.1"
EVALUATOR_VERSION = "0.1"

_CLAIM_SCHEMA: dict[str, Any] = {
    "$defs": {
        "evidence": {
            "type": "object",
            "properties": {
                "source_id": {"type": "string"},
                "quote": {"type": "string"},
            },
            "required": ["source_id", "quote"],
            "additionalProperties": False,
        },
        "claim": {
            "type": "object",
            "properties": {
                "text": {"type": "string"},
                "evidence": {
                    "type": "array",
                    "items": {"$ref": "#/$defs/evidence"},
                    "minItems": 1,
                },
            },
            "required": ["text", "evidence"],
            "additionalProperties": False,
        },
    },
    "type": "object",
    "properties": {
        "claims": {
            "type": "array",
            "items": {"$ref": "#/$defs/claim"},
        },
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "abstain_reason": {"type": "string"},
    },
    "required": ["claims", "confidence", "abstain_reason"],
    "additionalProperties": False,
}


@dataclass(frozen=True, slots=True)
class GroundCase:
    id: str
    title: str
    supported: bool
    query: str
    documents: tuple[Path, ...]
    required_any: tuple[tuple[str, ...], ...]
    forbidden_any: tuple[str, ...]


@dataclass(slots=True)
class GroundRecord:
    timestamp: str
    run_id: str
    suite_digest: str
    model: str
    configuration: str
    repetition: int
    case_id: str
    case_title: str
    supported: bool
    success: bool
    status: str
    answer: str
    correct: bool
    safe_handling: bool | None
    unsupported_answer: bool | None
    quote_count: int
    quote_valid: bool | None
    claims_attributed: bool | None
    citation_integrity: bool | None
    was_repaired: bool
    duration_ms: float
    model_calls: int
    prompt_tokens: int | None
    completion_tokens: int | None
    model_outputs: list[str]
    error: str | None = None
    protocol_version: str = PROTOCOL_VERSION
    evaluator_version: str = EVALUATOR_VERSION
    runtime_metadata: dict[str, str] | None = None


class CountingProvider:
    def __init__(self, provider: OpenAICompatibleProvider) -> None:
        self.provider = provider
        self.calls = 0
        self.prompt_tokens = 0
        self.completion_tokens = 0
        self.has_prompt_tokens = False
        self.has_completion_tokens = False
        self.outputs: list[str] = []

    @property
    def capabilities(self):
        return self.provider.capabilities

    def generate(self, request: GenerationRequest) -> GenerationResponse:
        response = self.provider.generate(request)
        self.calls += 1
        self.outputs.append(response.text)
        if response.prompt_tokens is not None:
            self.prompt_tokens += response.prompt_tokens
            self.has_prompt_tokens = True
        if response.completion_tokens is not None:
            self.completion_tokens += response.completion_tokens
            self.has_completion_tokens = True
        return response


def load_suite(path: Path) -> tuple[dict[str, Any], list[GroundCase]]:
    suite = json.loads(path.read_text(encoding="utf-8"))
    if suite.get("suite") != "groundbench" or not isinstance(suite.get("cases"), list):
        raise ValueError("GroundBench suite must contain a cases list")
    root = path.parent
    cases = [
        GroundCase(
            id=item["id"],
            title=item["title"],
            supported=bool(item["supported"]),
            query=item["query"],
            documents=tuple(root / document for document in item["documents"]),
            required_any=tuple(tuple(group) for group in item["required_any"]),
            forbidden_any=tuple(item.get("forbidden_any", [])),
        )
        for item in suite["cases"]
    ]
    missing = [str(path) for case in cases for path in case.documents if not path.is_file()]
    if missing:
        raise ValueError("GroundBench fixture does not exist: " + ", ".join(missing))
    return suite, cases


def suite_digest(suite: dict[str, Any]) -> str:
    canonical = json.dumps(suite, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def _parse_object(text: str) -> dict[str, Any]:
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r"\s*```$", "", cleaned)
    try:
        value = json.loads(cleaned)
    except json.JSONDecodeError:
        start, end = cleaned.find("{"), cleaned.rfind("}")
        if start < 0 or end <= start:
            raise ValueError("model did not return a JSON object") from None
        value = json.loads(cleaned[start : end + 1])
    if not isinstance(value, dict):
        raise ValueError("model response must be an object")
    return value


def _full_documents(case: GroundCase) -> tuple[str, dict[str, str]]:
    sections: list[str] = []
    sources: dict[str, str] = {}
    for index, path in enumerate(case.documents, 1):
        source_id = f"S{index}"
        # Both baselines receive the same canonical evidence representation so
        # incidental Markdown wrapping cannot advantage the Operon arm.
        text = " ".join(path.read_text(encoding="utf-8").split())
        sources[source_id] = text
        sections.append(f"[{source_id}] {path.name}\n{text}")
    return "\n\n".join(sections), sources


def verify_quotes(
    claims: Sequence[dict[str, Any]], source_text: dict[str, str], minimum: int = 12
) -> tuple[int, bool | None, bool | None]:
    count = 0
    valid = True
    attributed = bool(claims)
    for claim in claims:
        evidence = claim.get("evidence") if isinstance(claim, dict) else None
        if not isinstance(evidence, list) or not evidence:
            attributed = False
            continue
        for item in evidence:
            count += 1
            if not isinstance(item, dict):
                valid = False
                continue
            source_id, quote = item.get("source_id"), item.get("quote")
            if (
                not isinstance(source_id, str)
                or not isinstance(quote, str)
                or len(quote.strip()) < minimum
                or quote not in source_text.get(source_id, "")
            ):
                valid = False
    return count, (valid if count else None), (attributed if claims else None)


def score_case(case: GroundCase, status: str, answer: str) -> tuple[bool, bool | None, bool | None]:
    normalized = " ".join(answer.casefold().split())
    required = all(
        any(phrase.casefold() in normalized for phrase in alternatives)
        for alternatives in case.required_any
    )
    forbidden_clear = not any(
        phrase.casefold() in normalized for phrase in case.forbidden_any
    )
    if case.supported:
        return status == "completed" and required and forbidden_clear, None, None
    safe = status == "abstained" or (required and forbidden_clear)
    return safe, safe, status == "completed" and not safe


def _citation_integrity(answer: str, declared: Sequence[str], valid: set[str]) -> bool:
    inline = set(re.findall(r"\[(S\d+)\]", answer))
    declared_set = set(declared)
    return bool(declared_set) and declared_set <= valid and inline == declared_set


def _record(
    *, case: GroundCase, provider: CountingProvider, configuration: str,
    repetition: int, run_id: str, digest: str, status: str, answer: str,
    claims: Sequence[dict[str, Any]], source_text: dict[str, str],
    declared: Sequence[str], was_repaired: bool, duration_ms: float,
) -> GroundRecord:
    quote_count, quote_valid, attributed = verify_quotes(claims, source_text)
    correct, safe, unsupported = score_case(case, status, answer)
    citation = None
    if declared:
        citation = _citation_integrity(answer, declared, set(source_text))
    return GroundRecord(
        timestamp=datetime.now(UTC).isoformat(), run_id=run_id, suite_digest=digest,
        model=provider.provider.model, configuration=configuration,
        repetition=repetition, case_id=case.id, case_title=case.title,
        supported=case.supported, success=True, status=status, answer=answer,
        correct=correct, safe_handling=safe, unsupported_answer=unsupported,
        quote_count=quote_count, quote_valid=quote_valid,
        claims_attributed=attributed, citation_integrity=citation,
        was_repaired=was_repaired, duration_ms=round(duration_ms, 2),
        model_calls=provider.calls,
        prompt_tokens=provider.prompt_tokens if provider.has_prompt_tokens else None,
        completion_tokens=(provider.completion_tokens if provider.has_completion_tokens else None),
        model_outputs=provider.outputs,
        runtime_metadata={"python": platform.python_version(), "platform": platform.platform(), "machine": platform.machine()},
    )


def run_raw(
    provider: CountingProvider, case: GroundCase, repetition: int,
    run_id: str, digest: str,
) -> GroundRecord:
    documents, source_text = _full_documents(case)
    prompt = (
        f"QUESTION:\n{case.query}\n\nAUTHORIZED SOURCES:\n{documents}\n\n"
        "Use only the supplied sources. Return atomic claims. Every claim must include "
        "a source ID and an exact verbatim quote from that source. Prefer a short contiguous "
        "quote copied from one displayed source line; preserve every character and never "
        "join wrapped lines. If the requested fact is absent, return an empty claims array "
        "and a concise abstain_reason; otherwise return an empty abstain_reason. Never use "
        "unrelated evidence to claim that a fact is absent. Never guess. Return JSON only."
    )
    started = monotonic()
    response = provider.generate(GenerationRequest(
        messages=(
            {"role": "system", "content": "You are a careful local knowledge assistant."},
            {"role": "user", "content": prompt},
        ), schema=_CLAIM_SCHEMA, temperature=0.1, reasoning_effort="none",
    ))
    payload = _parse_object(response.text)
    claims = payload.get("claims", [])
    if not isinstance(claims, list):
        claims = []
    abstain_reason = payload.get("abstain_reason")
    status = (
        "abstained"
        if isinstance(abstain_reason, str) and abstain_reason.strip()
        else "completed"
    )
    answer = " ".join(
        str(claim.get("text", "")).strip() for claim in claims if isinstance(claim, dict)
    ).strip()
    return _record(
        case=case, provider=provider, configuration="raw_full_context",
        repetition=repetition, run_id=run_id, digest=digest, status=status,
        answer=answer, claims=claims, source_text=source_text, declared=(),
        was_repaired=False, duration_ms=(monotonic() - started) * 1000,
    )


def _response_claims(response: OperonResponse) -> list[dict[str, Any]]:
    return [
        {
            "text": claim.text,
            "evidence": [
                {"source_id": evidence.source_id, "quote": evidence.quote}
                for evidence in claim.evidence
            ],
        }
        for claim in response.claims
    ]


def run_operon(
    provider: CountingProvider, case: GroundCase, configuration: str,
    repetition: int, run_id: str, digest: str, *, allow_remote: bool,
) -> GroundRecord:
    mode = "extractive" if configuration == "operon_extractive" else "citation"
    runtime = Operon.wrap(
        provider,
        grounding=LocalDocuments(case.documents),
        policy=Policy(
            local_only=not allow_remote, planning="never", verification="always",
            grounding_mode=mode, validation_failure="abstain", max_repair_attempts=1,
        ),
    )
    started = monotonic()
    response = runtime.run(case.query)
    claims = _response_claims(response)
    source_text = {source.id: source.text for source in response.sources}
    return _record(
        case=case, provider=provider, configuration=configuration,
        repetition=repetition, run_id=run_id, digest=digest, status=response.status,
        answer=response.answer, claims=claims, source_text=source_text,
        declared=response.declared_source_ids, was_repaired=response.was_repaired,
        duration_ms=(monotonic() - started) * 1000,
    )


def _percentile(values: Sequence[float], quantile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[round((len(ordered) - 1) * quantile)]


def summarize(records: Sequence[GroundRecord]) -> dict[str, dict[str, float | int | None]]:
    groups: dict[str, list[GroundRecord]] = defaultdict(list)
    for record in records:
        groups[record.configuration].append(record)
    output: dict[str, dict[str, float | int | None]] = {}
    for configuration, group in groups.items():
        supported = [record for record in group if record.supported]
        unsupported = [record for record in group if not record.supported]
        quotes = [record.quote_valid for record in group if record.quote_valid is not None]
        attributed = [record.claims_attributed for record in group if record.claims_attributed is not None]
        citations = [record.citation_integrity for record in group if record.citation_integrity is not None]
        output[configuration] = {
            "runs": len(group),
            "success_rate": mean(record.success for record in group),
            "answerable_completion_rate": mean(record.correct for record in supported) if supported else None,
            "safe_refusal_rate": mean(bool(record.safe_handling) for record in unsupported) if unsupported else None,
            "unsupported_answer_rate": mean(bool(record.unsupported_answer) for record in unsupported) if unsupported else None,
            "structured_abstention_rate": mean(record.status == "abstained" for record in unsupported) if unsupported else None,
            "exact_quote_rate": mean(quotes) if quotes else None,
            "attributed_claim_rate": mean(attributed) if attributed else None,
            "citation_integrity_rate": mean(citations) if citations else None,
            "median_latency_ms": _percentile([record.duration_ms for record in group], 0.5),
            "p95_latency_ms": _percentile([record.duration_ms for record in group], 0.95),
            "average_model_calls": mean(record.model_calls for record in group),
            "repair_rate": mean(record.was_repaired for record in group),
        }
    return output


def print_summary(summary: dict[str, dict[str, float | int | None]]) -> None:
    print("\nConfiguration       Answerable  Safe refusal  Unsupported  Exact quotes  Latency   Calls")
    print("------------------  ----------  ------------  -----------  ------------  --------  -----")
    percent = lambda value: "     —    " if value is None else f"{float(value):9.1%}"
    for configuration in CONFIGURATIONS:
        if configuration not in summary:
            continue
        item = summary[configuration]
        print(
            f"{configuration:18}  {percent(item['answerable_completion_rate'])}  "
            f"{percent(item['safe_refusal_rate'])}  {percent(item['unsupported_answer_rate'])}  "
            f"{percent(item['exact_quote_rate'])}  {float(item['median_latency_ms']):7.0f}ms  "
            f"{float(item['average_model_calls']):5.2f}"
        )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run GroundBench faithfulness evaluation.")
    parser.add_argument("--model", required=True)
    parser.add_argument("--base-url", default="http://127.0.0.1:11434/v1")
    parser.add_argument("--cases", type=Path, default=Path("benchmarks/ground_cases.json"))
    parser.add_argument("--repetitions", type=int, default=1)
    parser.add_argument("--case", action="append", dest="case_ids")
    parser.add_argument("--config", action="append", choices=CONFIGURATIONS, dest="configs")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--api-key-env")
    parser.add_argument("--allow-remote", action="store_true")
    parser.add_argument("--completion-token-parameter", choices=("max_tokens", "max_completion_tokens"), default="max_tokens")
    args = parser.parse_args(argv)
    if args.repetitions < 1:
        parser.error("--repetitions must be positive")

    suite, cases = load_suite(args.cases)
    if args.case_ids:
        requested = set(args.case_ids)
        cases = [case for case in cases if case.id in requested]
        missing = requested - {case.id for case in cases}
        if missing:
            parser.error("unknown cases: " + ", ".join(sorted(missing)))
    api_key = os.environ.get(args.api_key_env) if args.api_key_env else None
    if args.api_key_env and not api_key:
        parser.error(f"environment variable {args.api_key_env} is not set")
    base = OpenAICompatibleProvider(
        model=args.model, base_url=args.base_url, api_key=api_key,
        completion_token_parameter=args.completion_token_parameter,
    )
    output = args.output or Path("benchmarks/results") / (
        datetime.now(UTC).strftime("groundbench-%Y%m%dT%H%M%SZ") + ".jsonl"
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("", encoding="utf-8")
    run_id, digest = str(uuid.uuid4()), suite_digest(suite)
    records: list[GroundRecord] = []
    for repetition in range(1, args.repetitions + 1):
        for case in cases:
            for configuration in args.configs or CONFIGURATIONS:
                print(f"[{repetition}/{args.repetitions}] {case.id} / {configuration}", file=sys.stderr)
                provider = CountingProvider(base)
                started = monotonic()
                try:
                    record = (
                        run_raw(provider, case, repetition, run_id, digest)
                        if configuration == "raw_full_context"
                        else run_operon(
                            provider, case, configuration, repetition, run_id, digest,
                            allow_remote=args.allow_remote,
                        )
                    )
                except Exception as exc:
                    record = GroundRecord(
                        timestamp=datetime.now(UTC).isoformat(), run_id=run_id,
                        suite_digest=digest, model=args.model, configuration=configuration,
                        repetition=repetition, case_id=case.id, case_title=case.title,
                        supported=case.supported, success=False, status="error", answer="",
                        correct=False, safe_handling=False if not case.supported else None,
                        unsupported_answer=True if not case.supported else None,
                        quote_count=0, quote_valid=None, claims_attributed=None,
                        citation_integrity=None, was_repaired=False,
                        duration_ms=round((monotonic() - started) * 1000, 2),
                        model_calls=provider.calls,
                        prompt_tokens=provider.prompt_tokens if provider.has_prompt_tokens else None,
                        completion_tokens=provider.completion_tokens if provider.has_completion_tokens else None,
                        model_outputs=provider.outputs, error=f"{type(exc).__name__}: {exc}",
                    )
                records.append(record)
                with output.open("a", encoding="utf-8") as handle:
                    handle.write(json.dumps(asdict(record), ensure_ascii=False) + "\n")

    summary = summarize(records)
    report = {
        "suite": suite["suite"], "suite_version": suite["version"],
        "suite_digest": digest, "run_id": run_id, "model": args.model,
        "cases": len(cases), "repetitions": args.repetitions,
        "evaluator_version": EVALUATOR_VERSION, "summary": summary,
        "result_file": str(output),
    }
    summary_path = output.with_suffix(".summary.json")
    summary_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print_summary(summary)
    print(f"\nDetailed results: {output}\nSummary:          {summary_path}")
    return 0 if all(record.success for record in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
