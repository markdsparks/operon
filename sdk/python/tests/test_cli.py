from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from operon.cli import _load_output_schema


class CliTests(unittest.TestCase):
    def test_loads_output_schema_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "schema.json"
            path.write_text(
                json.dumps({"type": "object", "properties": {}}),
                encoding="utf-8",
            )

            self.assertEqual(
                _load_output_schema(str(path)),
                {"type": "object", "properties": {}},
            )

    def test_rejects_non_object_output_schema_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "schema.json"
            path.write_text("[]", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "must be a JSON object"):
                _load_output_schema(str(path))


if __name__ == "__main__":
    unittest.main()
