from __future__ import annotations

import os
import sqlite3
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

_SECONDS_PER_DAY = 86_400
JsonScalar = str | int | float | bool | None


@dataclass(frozen=True, slots=True)
class CacheKey:
    message_id: str
    chat_jid: str
    provider: str
    model: str
    language_hint: str


@dataclass(frozen=True, slots=True)
class CacheEntry:
    transcript: str
    detected_language: str | None
    duration_seconds: float | None

    def as_result(self, key: CacheKey) -> dict[str, JsonScalar]:
        return {
            "message_id": key.message_id,
            "chat_jid": key.chat_jid,
            "success": True,
            "transcript": self.transcript,
            "language": self.detected_language,
            "duration_seconds": self.duration_seconds,
            "provider": key.provider,
            "model": key.model,
            "message": "Loaded transcript from cache",
            "cached": True,
        }


@dataclass(frozen=True, slots=True)
class TranscriptCache:
    path: Path
    max_age_days: int
    max_entries: int
    now: Callable[[], int] = lambda: int(time.time())

    @classmethod
    def from_environment(cls, path: Path) -> TranscriptCache:
        return cls(
            path=path,
            max_age_days=cls._setting("WHATSAPP_MCP_TRANSCRIPT_CACHE_DAYS", 30),
            max_entries=cls._setting(
                "WHATSAPP_MCP_TRANSCRIPT_CACHE_MAX_ENTRIES",
                1000,
            ),
        )

    def get(self, key: CacheKey) -> CacheEntry | None:
        if self.max_entries <= 0:
            return None

        timestamp = self.now()
        with self._connect() as connection:
            self._prepare(connection, timestamp)
            row = connection.execute(
                """
                SELECT transcript, detected_language, duration_seconds
                FROM transcript_cache
                WHERE message_id = ? AND chat_jid = ? AND provider = ?
                  AND model = ? AND language_hint = ?
                """,
                self._key_values(key),
            ).fetchone()
            if row is None:
                return None
            _ = connection.execute(
                """
                UPDATE transcript_cache SET accessed_at = ?
                WHERE message_id = ? AND chat_jid = ? AND provider = ?
                  AND model = ? AND language_hint = ?
                """,
                (timestamp, *self._key_values(key)),
            )
        transcript, detected_language, duration_seconds = row
        if not isinstance(transcript, str):
            return None
        if not isinstance(detected_language, (str, type(None))):
            return None
        if not isinstance(duration_seconds, (int, float, type(None))):
            return None
        return CacheEntry(transcript, detected_language, duration_seconds)

    def put(self, key: CacheKey, entry: CacheEntry) -> None:
        if self.max_entries <= 0:
            return

        timestamp = self.now()
        with self._connect() as connection:
            self._prepare(connection, timestamp)
            _ = connection.execute(
                """
                INSERT INTO transcript_cache (
                    message_id, chat_jid, provider, model, language_hint,
                    transcript, detected_language, duration_seconds,
                    created_at, accessed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(message_id, chat_jid, provider, model, language_hint)
                DO UPDATE SET
                    transcript = excluded.transcript,
                    detected_language = excluded.detected_language,
                    duration_seconds = excluded.duration_seconds,
                    created_at = excluded.created_at,
                    accessed_at = excluded.accessed_at
                """,
                (
                    *self._key_values(key),
                    entry.transcript,
                    entry.detected_language,
                    entry.duration_seconds,
                    timestamp,
                    timestamp,
                ),
            )
            _ = connection.execute(
                """
                DELETE FROM transcript_cache
                WHERE rowid IN (
                    SELECT rowid FROM transcript_cache
                    ORDER BY accessed_at DESC, created_at DESC
                    LIMIT -1 OFFSET ?
                )
                """,
                (self.max_entries,),
            )

    def _connect(self) -> sqlite3.Connection:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        return sqlite3.connect(self.path)

    def _prepare(self, connection: sqlite3.Connection, timestamp: int) -> None:
        _ = connection.execute(
            """
            CREATE TABLE IF NOT EXISTS transcript_cache (
                message_id TEXT NOT NULL,
                chat_jid TEXT NOT NULL,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                language_hint TEXT NOT NULL,
                transcript TEXT NOT NULL,
                detected_language TEXT,
                duration_seconds REAL,
                created_at INTEGER NOT NULL,
                accessed_at INTEGER NOT NULL,
                PRIMARY KEY (message_id, chat_jid, provider, model, language_hint)
            )
            """
        )
        cutoff = timestamp - max(self.max_age_days, 0) * _SECONDS_PER_DAY
        _ = connection.execute(
            "DELETE FROM transcript_cache WHERE accessed_at < ?",
            (cutoff,),
        )

    @staticmethod
    def _key_values(key: CacheKey) -> tuple[str, str, str, str, str]:
        return (
            key.message_id,
            key.chat_jid,
            key.provider,
            key.model,
            key.language_hint,
        )

    @staticmethod
    def _setting(name: str, default: int) -> int:
        raw_value = os.environ.get(name)
        if raw_value is None:
            return default
        try:
            return max(int(raw_value), 0)
        except ValueError:
            return default
