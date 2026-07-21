from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Sequence

from .run import CONFIGURATIONS, RunRecord, summarize


def model_slug(model: str) -> str:
    return re.sub(r"[^a-zA-Z0-9._-]+", "-", model).strip("-") or "model"


def read_records(path: Path) -> list[RunRecord]:
    return [
        RunRecord(**json.loads(line))
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def aggregate_matrix(paths: dict[str, Path]) -> dict[str, dict[str, Any]]:
    aggregate: dict[str, dict[str, Any]] = {}
    for model, path in paths.items():
        records = read_records(path)
        aggregate[model] = {
            "result_file": str(path),
            "summary": summarize(records),
            "runs": len(records),
            "failures": sum(not record.success for record in records),
            "case_digests": sorted({record.case_digest for record in records}),
            "run_ids": sorted({record.run_id for record in records}),
        }
    return aggregate


def print_matrix(aggregate: dict[str, dict[str, Any]]) -> None:
    print(
        "\nModel                 Configuration         Decision  Complete  Provenance  "
        "Recall  Latency   Calls"
    )
    print(
        "--------------------  --------------------  --------  --------  ----------  "
        "------  --------  -----"
    )
    percent = lambda value: "   —   " if value is None else f"{float(value):7.1%}"
    for model, model_data in aggregate.items():
        for configuration in CONFIGURATIONS:
            summary = model_data["summary"].get(configuration)
            if summary is None:
                continue
            print(
                f"{model[:20]:20}  {configuration:20}  "
                f"{percent(summary['accuracy'])}  {percent(summary['completeness'])}  "
                f"{percent(summary['provenance_rate'])}  {percent(summary['source_recall'])}  "
                f"{float(summary['average_latency_ms']):7.0f}ms  "
                f"{float(summary['average_model_calls']):5.2f}"
            )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run and aggregate Operon benchmarks across local models."
    )
    parser.add_argument("--model", action="append", required=True, dest="models")
    parser.add_argument("--base-url", default="http://127.0.0.1:11434/v1")
    parser.add_argument("--cases", type=Path, default=Path("benchmarks/cases.json"))
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--case", action="append", dest="case_ids")
    parser.add_argument("--config", action="append", choices=CONFIGURATIONS, dest="configs")
    parser.add_argument("--output-dir", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    output_dir = args.output_dir or Path("benchmarks/results") / datetime.now(UTC).strftime(
        "matrix-%Y%m%dT%H%M%SZ"
    )
    output_dir.mkdir(parents=True, exist_ok=True)
    result_paths: dict[str, Path] = {}
    failed_models: list[str] = []

    for model in args.models:
        output = output_dir / f"{model_slug(model)}.jsonl"
        command = [
            sys.executable,
            "-m",
            "benchmarks.run",
            "--model",
            model,
            "--base-url",
            args.base_url,
            "--cases",
            str(args.cases),
            "--repetitions",
            str(args.repetitions),
            "--output",
            str(output),
        ]
        for case_id in args.case_ids or []:
            command.extend(("--case", case_id))
        for configuration in args.configs or []:
            command.extend(("--config", configuration))
        print(f"\n=== {model} ===", flush=True)
        completed = subprocess.run(command, env=os.environ.copy(), check=False)
        if completed.returncode != 0:
            failed_models.append(model)
        if output.exists():
            result_paths[model] = output

    aggregate = aggregate_matrix(result_paths)
    summary_path = output_dir / "matrix-summary.json"
    summary_path.write_text(json.dumps(aggregate, indent=2), encoding="utf-8")
    print_matrix(aggregate)
    print(f"\nMatrix summary: {summary_path}")
    if failed_models:
        print(f"Models with failed cells: {', '.join(failed_models)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

