from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from operon.grounding import LocalDocuments


class LocalDocumentsTests(unittest.TestCase):
    def test_returns_relevant_chunks_with_stable_ids(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "returns.md").write_text(
                "Refunds are accepted for 30 days with a receipt.", encoding="utf-8"
            )
            (root / "shipping.md").write_text(
                "Standard shipping takes five business days.", encoding="utf-8"
            )

            results = LocalDocuments(root).search("What is the refund period?")

            self.assertEqual(len(results), 1)
            self.assertEqual(results[0].id, "S1")
            self.assertTrue(results[0].path.endswith("returns.md"))
            self.assertIn("30 days", results[0].text)

    def test_missing_path_produces_empty_index(self) -> None:
        documents = LocalDocuments("/path/that/does/not/exist")
        self.assertEqual(documents.search("anything"), ())


if __name__ == "__main__":
    unittest.main()
