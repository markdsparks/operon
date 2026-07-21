from __future__ import annotations

import argparse
import json
from dataclasses import asdict
from pathlib import Path
from typing import Sequence

from .run import (
    EVALUATOR_VERSION,
    RunRecord,
    _print_summary,
    load_cases,
    score_answer,
    summarize,
)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Reapply the current deterministic evaluator to saved benchmark output."
    )
    parser.add_argument("input", type=Path)
    parser.add_argument("--cases", type=Path, default=Path("benchmarks/cases.json"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)

    cases = {case.id: case for case in load_cases(args.cases)}
    records: list[RunRecord] = []
    for line in args.input.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        record = RunRecord(**json.loads(line))
        record.evaluator_version = EVALUATOR_VERSION
        if record.success and record.case_id in cases:
            (
                record.correct,
                record.complete,
                record.required_checks,
                record.forbidden_check,
                recall,
                precision,
            ) = score_answer(
                cases[record.case_id],
                record.answer,
                record.returned_sources or [],
            )
            if record.configuration == "question_only":
                record.expected_source_recall = None
                record.expected_source_precision = None
            else:
                record.expected_source_recall = recall
                record.expected_source_precision = precision
        records.append(record)

    output = args.output or args.input.with_name(args.input.stem + ".rescored.jsonl")
    output.write_text(
        "".join(json.dumps(asdict(record), ensure_ascii=False) + "\n" for record in records),
        encoding="utf-8",
    )
    summary = summarize(records)
    summary_path = output.with_suffix(".summary.json")
    summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    _print_summary(summary)
    print(f"\nRescored results: {output}")
    print(f"Summary:          {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
