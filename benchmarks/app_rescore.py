"""Reapply the current AppBench evaluator to saved model interactions."""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict
from pathlib import Path
from typing import Sequence

from .appbench import (
    EVALUATOR_VERSION,
    AppRecord,
    _score,
    load_suite,
    print_summary,
    summarize,
)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Reapply the current AppBench evaluator to saved output."
    )
    parser.add_argument("input", type=Path)
    parser.add_argument(
        "--cases", type=Path, default=Path("benchmarks/app_cases.json")
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)

    suite = load_suite(args.cases)
    cases = {case["id"]: case for case in suite["cases"]}
    records: list[AppRecord] = []
    for line in args.input.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        record = AppRecord(**json.loads(line))
        case = cases.get(record.case_id)
        if case is None:
            raise ValueError(f"saved result references unknown case: {record.case_id}")
        score = _score(
            case,
            record.outcome,
            record.attempted_calls,
            record.invoked_calls,
            record.outcome == "rejected",
            record.error,
        )
        for name, value in score.items():
            setattr(record, name, value)
        record.evaluator_version = EVALUATOR_VERSION
        records.append(record)

    output = args.output or args.input.with_name(
        args.input.stem + f"-eval-{EVALUATOR_VERSION}.jsonl"
    )
    output.write_text(
        "".join(json.dumps(asdict(record), sort_keys=True) + "\n" for record in records),
        encoding="utf-8",
    )
    summary = summarize(records)
    first = records[0]
    report = {
        "suite": suite["suite"],
        "suite_version": suite["version"],
        "suite_digest": first.suite_digest,
        "run_id": first.run_id,
        "model": first.model,
        "cases": len({record.case_id for record in records}),
        "repetitions": max(record.repetition for record in records),
        "evaluator_version": EVALUATOR_VERSION,
        "summary": summary,
        "result_file": str(output),
    }
    summary_path = output.with_suffix(".summary.json")
    summary_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print_summary(summary)
    print(f"\nRescored results: {output}")
    print(f"Summary: {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
