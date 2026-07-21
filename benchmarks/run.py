from __future__ import annotations

import argparse
import hashlib
import json
import platform
import os
import re
import sys
import uuid
from collections import defaultdict
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from statistics import mean
from time import monotonic
from typing import Any, Iterable, Sequence

from operon import (
    LocalDocuments,
    OpenAICompatibleProvider,
    Operon,
    Policy,
    __version__ as operon_version,
)
from operon.models import GenerationRequest, OperonResponse


CONFIGURATIONS = (
    "question_only",
    "all_context",
    "operon_unverified",
    "operon_full",
)
PROTOCOL_VERSION = "1.0"
EVALUATOR_VERSION = "1.2"

_ANSWER_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "answer": {"type": "string"},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "used_source_ids": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["answer", "confidence", "used_source_ids"],
    "additionalProperties": False,
}


@dataclass(frozen=True, slots=True)
class Case:
    id: str
    title: str
    expected_verdict: str
    query: str
    documents: tuple[Path, ...]
    required_any: tuple[tuple[str, ...], ...]
    forbidden_any: tuple[str, ...]
    expected_sources: tuple[str, ...]
    accepted_exact: tuple[str, ...] = ()


@dataclass(slots=True)
class RunRecord:
    timestamp: str
    model: str
    case_id: str
    case_title: str
    configuration: str
    repetition: int
    success: bool
    correct: bool
    complete: bool = False
    answer: str = ""
    confidence: float | None = None
    required_checks: list[bool] | None = None
    forbidden_check: bool = False
    declared_source_ids: list[str] | None = None
    returned_sources: list[str] | None = None
    expected_source_recall: float | None = None
    expected_source_precision: float | None = None
    provenance_valid: bool | None = None
    was_repaired: bool = False
    duration_ms: float = 0.0
    model_calls: int = 0
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    context_chars: int = 0
    error: str | None = None
    trace: list[dict[str, Any]] | None = None
    protocol_version: str = PROTOCOL_VERSION
    evaluator_version: str = EVALUATOR_VERSION
    operon_version: str = operon_version
    run_id: str = ""
    case_digest: str = ""
    runtime_metadata: dict[str, str] | None = None
    profile: str = ""


def load_cases(path: Path) -> list[Case]:
    raw_cases = json.loads(path.read_text(encoding="utf-8"))
    root = path.parent
    return [
        Case(
            id=item["id"],
            title=item["title"],
            expected_verdict=item["expected_verdict"],
            query=item["query"],
            documents=tuple(root / document for document in item["documents"]),
            required_any=tuple(tuple(group) for group in item["required_any"]),
            forbidden_any=tuple(item.get("forbidden_any", [])),
            expected_sources=tuple(item.get("expected_sources", [])),
            accepted_exact=tuple(item.get("accepted_exact", [])),
        )
        for item in raw_cases
    ]


def case_digest(case: Case) -> str:
    digest = hashlib.sha256()
    digest.update(case.id.encode())
    digest.update(case.query.encode())
    digest.update(case.expected_verdict.encode())
    digest.update(json.dumps(case.required_any, sort_keys=True).encode())
    digest.update(json.dumps(case.forbidden_any, sort_keys=True).encode())
    digest.update(json.dumps(case.accepted_exact, sort_keys=True).encode())
    for path in case.documents:
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def stamp_record(record: RunRecord, run_id: str, case: Case) -> None:
    record.run_id = run_id
    record.case_digest = case_digest(case)
    record.runtime_metadata = {
        "python": platform.python_version(),
        "platform": platform.platform(),
        "machine": platform.machine(),
    }


def score_answer(
    case: Case,
    answer: str,
    returned_sources: Iterable[str],
) -> tuple[bool, bool, list[bool], bool, float | None, float | None]:
    normalized = " ".join(answer.casefold().split())
    required_checks = [
        any(phrase.casefold() in normalized for phrase in alternatives)
        for alternatives in case.required_any
    ]
    forbidden_check = not any(
        phrase.casefold() in normalized for phrase in case.forbidden_any
    )
    returned_names = {Path(source).name for source in returned_sources}
    expected = set(case.expected_sources)
    source_recall = (
        len(returned_names & expected) / len(expected) if expected else None
    )
    source_precision = (
        len(returned_names & expected) / len(returned_names)
        if returned_names
        else (0.0 if expected else None)
    )
    verdict_text = re.sub(r"\[s\d+\]", "", normalized).strip().rstrip(".")
    terse_verdict_match = case.expected_verdict == "deny" and verdict_text == "no"
    exact_match = verdict_text in {item.casefold() for item in case.accepted_exact}
    return (
        bool(required_checks)
        and (required_checks[0] or terse_verdict_match or exact_match)
        and forbidden_check,
        all(required_checks) and forbidden_check,
        required_checks,
        forbidden_check,
        source_recall,
        source_precision,
    )


def _parse_json_object(text: str) -> dict[str, Any]:
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


def _format_documents(case: Case) -> tuple[str, dict[str, str]]:
    sections: list[str] = []
    source_map: dict[str, str] = {}
    for index, path in enumerate(case.documents, start=1):
        source_id = f"S{index}"
        source_map[source_id] = str(path)
        sections.append(f"[{source_id}] {path.name}\n{path.read_text(encoding='utf-8')}")
    return "\n\n".join(sections), source_map


def _provenance(
    answer: str,
    declared_ids: list[str],
    valid_ids: set[str],
) -> bool:
    cited_ids = set(re.findall(r"\[(S\d+)\]", answer))
    declared = set(declared_ids)
    return declared.issubset(valid_ids) and cited_ids == declared


def run_direct(
    provider: OpenAICompatibleProvider,
    case: Case,
    configuration: str,
    repetition: int,
) -> RunRecord:
    documents, source_map = _format_documents(case)
    if configuration == "question_only":
        context = "No company documents were supplied. Do not invent a policy or source."
        source_map = {}
    else:
        context = f"AUTHORIZED COMPANY SOURCES:\n{documents}"
    prompt = (
        f"QUESTION:\n{case.query}\n\n{context}\n\n"
        "Answer the question directly. Use only authorized sources for company-specific facts. "
        "When sources are supplied, cite each used source inline as [S1] and list exactly the "
        "same IDs in used_source_ids. Return JSON only."
    )
    started = monotonic()
    response = provider.generate(
        GenerationRequest(
            messages=(
                {"role": "system", "content": "You are a careful policy analyst."},
                {"role": "user", "content": prompt},
            ),
            schema=_ANSWER_SCHEMA,
            temperature=0.1,
            reasoning_effort="none",
        )
    )
    duration_ms = (monotonic() - started) * 1000
    payload = _parse_json_object(response.text)
    answer = str(payload.get("answer", ""))
    confidence = payload.get("confidence")
    declared = payload.get("used_source_ids", [])
    if not isinstance(declared, list):
        declared = []
    declared = [item for item in declared if isinstance(item, str)]
    returned_sources = [source_map[item] for item in declared if item in source_map]
    correct, complete, checks, forbidden, recall, precision = score_answer(
        case, answer, returned_sources
    )
    return RunRecord(
        timestamp=datetime.now(UTC).isoformat(),
        model=provider.model,
        case_id=case.id,
        case_title=case.title,
        configuration=configuration,
        repetition=repetition,
        success=True,
        correct=correct,
        complete=complete,
        answer=answer,
        confidence=float(confidence) if isinstance(confidence, (int, float)) else None,
        required_checks=checks,
        forbidden_check=forbidden,
        declared_source_ids=declared,
        returned_sources=returned_sources,
        expected_source_recall=recall if source_map else None,
        expected_source_precision=precision if source_map else None,
        provenance_valid=_provenance(answer, declared, set(source_map)) if source_map else None,
        duration_ms=round(duration_ms, 2),
        model_calls=1,
        prompt_tokens=response.prompt_tokens,
        completion_tokens=response.completion_tokens,
        context_chars=len(documents) if source_map else 0,
        trace=[
            {
                "stage": "generate",
                "prompt_tokens": response.prompt_tokens,
                "completion_tokens": response.completion_tokens,
                "finish_reason": response.finish_reason,
            }
        ],
    )


def _trace_data(response: OperonResponse) -> tuple[list[dict[str, Any]], int, int | None, int | None, int]:
    trace = [
        {
            "stage": event.stage.value,
            "message": event.message,
            "elapsed_ms": event.elapsed_ms,
            "data": event.data,
        }
        for event in response.trace.events
    ]
    generation_events = [event for event in response.trace.events if "prompt_tokens" in event.data]
    prompt_values = [event.data["prompt_tokens"] for event in generation_events if event.data["prompt_tokens"] is not None]
    completion_values = [event.data["completion_tokens"] for event in generation_events if event.data["completion_tokens"] is not None]
    context_chars = sum(int(event.data.get("context_chars", 0)) for event in generation_events)
    return (
        trace,
        len(generation_events),
        sum(prompt_values) if prompt_values else None,
        sum(completion_values) if completion_values else None,
        context_chars,
    )


def run_operon(
    provider: OpenAICompatibleProvider,
    case: Case,
    configuration: str,
    repetition: int,
    *,
    allow_remote: bool = False,
) -> RunRecord:
    verification = "never" if configuration == "operon_unverified" else "adaptive"
    runtime = Operon(
        provider,
        grounding=LocalDocuments(case.documents),
        # Local-only is the product default. A benchmark can opt into a remote
        # reference only through the explicit command-line/profile switch.
        policy=Policy(
            local_only=not allow_remote,
            planning="always",
            verification=verification,
        ),
    )
    started = monotonic()
    response = runtime.run(case.query)
    duration_ms = (monotonic() - started) * 1000
    returned_sources = [source.path for source in response.sources]
    correct, complete, checks, forbidden, recall, precision = score_answer(
        case, response.answer, returned_sources
    )
    trace, calls, prompt_tokens, completion_tokens, context_chars = _trace_data(response)
    valid_ids = {source.id for source in response.sources}
    return RunRecord(
        timestamp=datetime.now(UTC).isoformat(),
        model=provider.model,
        case_id=case.id,
        case_title=case.title,
        configuration=configuration,
        repetition=repetition,
        success=True,
        correct=correct,
        complete=complete,
        answer=response.answer,
        confidence=response.confidence,
        required_checks=checks,
        forbidden_check=forbidden,
        declared_source_ids=list(response.declared_source_ids),
        returned_sources=returned_sources,
        expected_source_recall=recall,
        expected_source_precision=precision,
        provenance_valid=_provenance(
            response.answer, list(response.declared_source_ids), valid_ids
        ),
        was_repaired=response.was_repaired,
        duration_ms=round(duration_ms, 2),
        model_calls=calls,
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        context_chars=context_chars,
        trace=trace,
    )


def summarize(records: Sequence[RunRecord]) -> dict[str, dict[str, float | int | None]]:
    grouped: dict[str, list[RunRecord]] = defaultdict(list)
    for record in records:
        grouped[record.configuration].append(record)
    summary: dict[str, dict[str, float | int | None]] = {}
    for configuration, group in grouped.items():
        provenance = [record.provenance_valid for record in group if record.provenance_valid is not None]
        recalls = [record.expected_source_recall for record in group if record.expected_source_recall is not None]
        precisions = [record.expected_source_precision for record in group if record.expected_source_precision is not None]
        prompt_tokens = [record.prompt_tokens for record in group if record.prompt_tokens is not None]
        completion_tokens = [record.completion_tokens for record in group if record.completion_tokens is not None]
        summary[configuration] = {
            "runs": len(group),
            "success_rate": mean(record.success for record in group),
            "accuracy": mean(record.correct for record in group),
            "completeness": mean(record.complete for record in group),
            "provenance_rate": mean(provenance) if provenance else None,
            "source_recall": mean(recalls) if recalls else None,
            "source_precision": mean(precisions) if precisions else None,
            "average_latency_ms": mean(record.duration_ms for record in group),
            "median_latency_ms": _percentile([record.duration_ms for record in group], 0.5),
            "p95_latency_ms": _percentile([record.duration_ms for record in group], 0.95),
            "average_model_calls": mean(record.model_calls for record in group),
            "average_prompt_tokens": mean(prompt_tokens) if prompt_tokens else None,
            "average_completion_tokens": mean(completion_tokens) if completion_tokens else None,
            "repair_rate": mean(record.was_repaired for record in group),
        }
    return summary


def _percentile(values: list[float], quantile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = round((len(ordered) - 1) * quantile)
    return ordered[index]


def _print_summary(summary: dict[str, dict[str, float | int | None]]) -> None:
    print("\nConfiguration         Decision  Complete  Provenance  Src recall  Latency   Calls  Repairs")
    print("--------------------  --------  --------  ----------  ----------  --------  -----  -------")
    for configuration in CONFIGURATIONS:
        if configuration not in summary:
            continue
        item = summary[configuration]
        percent = lambda value: "   —   " if value is None else f"{float(value):7.1%}"
        print(
            f"{configuration:20}  {percent(item['accuracy'])}  "
            f"{percent(item['completeness'])}  "
            f"{percent(item['provenance_rate'])}  {percent(item['source_recall'])}  "
            f"{float(item['average_latency_ms']):7.0f}ms  "
            f"{float(item['average_model_calls']):5.2f}  {percent(item['repair_rate'])}"
        )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the Operon SLM evaluation matrix.")
    parser.add_argument("--model", required=True)
    parser.add_argument("--base-url", default="http://127.0.0.1:11434/v1")
    parser.add_argument("--cases", type=Path, default=Path("benchmarks/cases.json"))
    parser.add_argument("--repetitions", type=int, default=1)
    parser.add_argument("--case", action="append", dest="case_ids")
    parser.add_argument("--config", action="append", choices=CONFIGURATIONS, dest="configs")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--profile", default="local")
    parser.add_argument("--api-key-env")
    parser.add_argument(
        "--allow-remote",
        action="store_true",
        help="Permit the Operon configurations to use a non-local inference provider.",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.repetitions < 1:
        print("benchmark: --repetitions must be positive", file=sys.stderr)
        return 2
    cases = load_cases(args.cases)
    if args.case_ids:
        requested = set(args.case_ids)
        cases = [case for case in cases if case.id in requested]
        missing = requested - {case.id for case in cases}
        if missing:
            print(f"benchmark: unknown cases: {', '.join(sorted(missing))}", file=sys.stderr)
            return 2
    configurations = args.configs or list(CONFIGURATIONS)
    output = args.output or Path("benchmarks/results") / (
        datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ") + ".jsonl"
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("", encoding="utf-8")
    api_key = os.environ.get(args.api_key_env) if args.api_key_env else None
    if args.api_key_env and not api_key:
        print(f"benchmark: environment variable {args.api_key_env} is not set", file=sys.stderr)
        return 2
    provider = OpenAICompatibleProvider(model=args.model, base_url=args.base_url, api_key=api_key)
    records: list[RunRecord] = []
    run_id = str(uuid.uuid4())

    for repetition in range(1, args.repetitions + 1):
        for case in cases:
            for configuration in configurations:
                print(
                    f"[{repetition}/{args.repetitions}] {case.id} / {configuration}",
                    file=sys.stderr,
                )
                started = monotonic()
                try:
                    if configuration in {"question_only", "all_context"}:
                        record = run_direct(provider, case, configuration, repetition)
                    else:
                        record = run_operon(
                            provider,
                            case,
                            configuration,
                            repetition,
                            allow_remote=args.allow_remote,
                        )
                except Exception as exc:  # Preserve the matrix when one cell fails.
                    record = RunRecord(
                        timestamp=datetime.now(UTC).isoformat(),
                        model=args.model,
                        case_id=case.id,
                        case_title=case.title,
                        configuration=configuration,
                        repetition=repetition,
                        success=False,
                        correct=False,
                        duration_ms=round((monotonic() - started) * 1000, 2),
                        error=f"{type(exc).__name__}: {exc}",
                    )
                stamp_record(record, run_id, case)
                record.profile = args.profile
                records.append(record)
                with output.open("a", encoding="utf-8") as handle:
                    handle.write(json.dumps(asdict(record), ensure_ascii=False) + "\n")

    summary = summarize(records)
    summary_path = output.with_suffix(".summary.json")
    summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    _print_summary(summary)
    print(f"\nDetailed results: {output}")
    print(f"Summary:          {summary_path}")
    return 0 if all(record.success for record in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
