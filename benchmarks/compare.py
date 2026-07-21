"""Run a fair local/cloud benchmark matrix from an explicit profile manifest."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Sequence

from .matrix import read_records
from .run import CONFIGURATIONS, RunRecord, summarize


@dataclass(frozen=True, slots=True)
class Profile:
    name: str
    model: str
    base_url: str
    api_key_env: str | None = None
    input_cost_per_million: float = 0
    output_cost_per_million: float = 0


def load_profiles(path: Path) -> list[Profile]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    return [Profile(**item) for item in raw]


def estimated_cost(record: RunRecord, profile: Profile) -> float | None:
    if record.prompt_tokens is None or record.completion_tokens is None:
        return None
    return (
        record.prompt_tokens * profile.input_cost_per_million
        + record.completion_tokens * profile.output_cost_per_million
    ) / 1_000_000


def comparison(records: list[RunRecord], profiles: list[Profile]) -> dict[str, Any]:
    output: dict[str, Any] = {}
    for profile in profiles:
        profile_records = [record for record in records if record.profile == profile.name]
        summaries = summarize(profile_records)
        for configuration, summary in summaries.items():
            costs = [estimated_cost(record, profile) for record in profile_records if record.configuration == configuration]
            known_costs = [cost for cost in costs if cost is not None]
            summary["estimated_average_cost_usd"] = sum(known_costs) / len(known_costs) if known_costs else None
        output[profile.name] = {"model": profile.model, "summary": summaries}
    return output


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Compare local and cloud Operon profiles fairly.")
    parser.add_argument("--profiles", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--case", action="append", dest="case_ids")
    parser.add_argument("--config", action="append", choices=CONFIGURATIONS, dest="configs")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    profiles = load_profiles(args.profiles)
    output_dir = args.output_dir or Path("benchmarks/results") / datetime.now(UTC).strftime("compare-%Y%m%dT%H%M%SZ")
    output_dir.mkdir(parents=True, exist_ok=True)
    paths: list[Path] = []
    for profile in profiles:
        output = output_dir / f"{profile.name}.jsonl"
        command = [sys.executable, "-m", "benchmarks.run", "--model", profile.model, "--base-url", profile.base_url, "--profile", profile.name, "--repetitions", str(args.repetitions), "--output", str(output)]
        if profile.api_key_env:
            command.extend(("--api-key-env", profile.api_key_env))
        for case_id in args.case_ids or []:
            command.extend(("--case", case_id))
        for config in args.configs or []:
            command.extend(("--config", config))
        if subprocess.run(command, check=False).returncode:
            return 1
        paths.append(output)
    records = [record for path in paths for record in read_records(path)]
    report = comparison(records, profiles)
    report_path = output_dir / "comparison.json"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Comparison: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
