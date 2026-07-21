from __future__ import annotations

import math
import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

from .models import Source


_TOKEN = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]+")
_DEFAULT_EXTENSIONS = frozenset(
    {".md", ".txt", ".rst", ".json", ".yaml", ".yml", ".csv"}
)


def _tokens(text: str) -> list[str]:
    return [_normalize_term(match.group(0)) for match in _TOKEN.finditer(text)]


def _normalize_term(term: str) -> str:
    """Apply conservative English normalization without a heavyweight NLP runtime."""
    normalized = term.lower()
    if len(normalized) > 4 and normalized.endswith("ies"):
        return normalized[:-3] + "y"
    if len(normalized) > 4 and normalized.endswith("es"):
        return normalized[:-2]
    if len(normalized) > 3 and normalized.endswith("s") and not normalized.endswith("ss"):
        return normalized[:-1]
    return normalized


@dataclass(frozen=True, slots=True)
class _Chunk:
    path: str
    index: int
    text: str
    terms: Counter[str]


@dataclass(slots=True)
class LocalDocuments:
    """Dependency-free lexical grounding for local text documents.

    This intentionally starts small. Its interface can later be backed by vector,
    hybrid, or platform-native indexes without changing the Operon runtime.
    """

    paths: tuple[Path, ...]
    chunk_chars: int = 2_400
    overlap_chars: int = 240
    extensions: frozenset[str] = _DEFAULT_EXTENSIONS
    _chunks: list[_Chunk] = field(default_factory=list, init=False, repr=False)
    _document_frequency: Counter[str] = field(
        default_factory=Counter, init=False, repr=False
    )

    def __init__(
        self,
        paths: str | Path | Iterable[str | Path],
        *,
        chunk_chars: int = 2_400,
        overlap_chars: int = 240,
        extensions: frozenset[str] = _DEFAULT_EXTENSIONS,
    ) -> None:
        if isinstance(paths, (str, Path)):
            normalized = (Path(paths),)
        else:
            normalized = tuple(Path(path) for path in paths)
        if chunk_chars < 100:
            raise ValueError("chunk_chars must be at least 100")
        if overlap_chars < 0 or overlap_chars >= chunk_chars:
            raise ValueError("overlap_chars must be between 0 and chunk_chars")

        self.paths = normalized
        self.chunk_chars = chunk_chars
        self.overlap_chars = overlap_chars
        self.extensions = extensions
        self._chunks = []
        self._document_frequency = Counter()
        self._index()

    def _index(self) -> None:
        for path in self._iter_files():
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            for index, chunk_text in enumerate(self._split(text)):
                terms = Counter(_tokens(chunk_text))
                if not terms:
                    continue
                chunk = _Chunk(str(path), index, chunk_text, terms)
                self._chunks.append(chunk)
                self._document_frequency.update(terms.keys())

    def _iter_files(self) -> Iterable[Path]:
        for path in self.paths:
            if path.is_file() and path.suffix.lower() in self.extensions:
                yield path
            elif path.is_dir():
                for child in sorted(path.rglob("*")):
                    if child.is_file() and child.suffix.lower() in self.extensions:
                        yield child

    def _split(self, text: str) -> Iterable[str]:
        start = 0
        length = len(text)
        while start < length:
            target = min(start + self.chunk_chars, length)
            end = target
            if target < length:
                boundary = max(
                    text.rfind("\n\n", start, target),
                    text.rfind(". ", start, target),
                    text.rfind("\n", start, target),
                )
                if boundary > start + self.chunk_chars // 2:
                    end = boundary + 1
            chunk = text[start:end].strip()
            if chunk:
                yield chunk
            if end >= length:
                break
            start = max(start + 1, end - self.overlap_chars)

    def search(self, query: str, *, limit: int = 5) -> tuple[Source, ...]:
        query_terms = Counter(_tokens(query))
        if not query_terms or not self._chunks or limit < 1:
            return ()

        total = len(self._chunks)
        scored: list[tuple[float, _Chunk]] = []
        for chunk in self._chunks:
            score = 0.0
            size_normalizer = 1.0 + 0.2 * math.log1p(sum(chunk.terms.values()))
            for term, query_count in query_terms.items():
                frequency = chunk.terms.get(term, 0)
                if not frequency:
                    continue
                document_frequency = self._document_frequency[term]
                inverse_frequency = math.log((total + 1) / (document_frequency + 0.5)) + 1
                score += query_count * (1 + math.log(frequency)) * inverse_frequency
            if score > 0:
                scored.append((score / size_normalizer, chunk))

        scored.sort(key=lambda item: (-item[0], item[1].path, item[1].index))
        return tuple(
            Source(
                id=f"S{rank}",
                path=chunk.path,
                text=chunk.text,
                score=round(score, 4),
            )
            for rank, (score, chunk) in enumerate(scored[:limit], start=1)
        )
