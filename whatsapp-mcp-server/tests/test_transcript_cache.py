from __future__ import annotations

from pathlib import Path

from transcript_cache import CacheEntry, CacheKey, TranscriptCache


def _key(message_id: str = "message-1") -> CacheKey:
    return CacheKey(
        message_id=message_id,
        chat_jid="chat@s.whatsapp.net",
        provider="local",
        model="large-v3",
        language_hint="",
    )


def _entry(transcript: str = "hello world") -> CacheEntry:
    return CacheEntry(
        transcript=transcript,
        detected_language="en",
        duration_seconds=1.25,
    )


def test_cache_reuses_persisted_transcript(tmp_path: Path) -> None:
    # Given
    cache_path = tmp_path / "transcripts.db"
    writer = TranscriptCache(cache_path, max_age_days=30, max_entries=100, now=lambda: 100)
    writer.put(_key(), _entry())

    # When
    reader = TranscriptCache(cache_path, max_age_days=30, max_entries=100, now=lambda: 101)
    cached = reader.get(_key())

    # Then
    assert cached == _entry()


def test_cache_expires_entries_after_retention_window(tmp_path: Path) -> None:
    # Given
    cache = TranscriptCache(tmp_path / "transcripts.db", max_age_days=1, max_entries=100, now=lambda: 100)
    cache.put(_key(), _entry())

    # When
    expired_cache = TranscriptCache(
        tmp_path / "transcripts.db",
        max_age_days=1,
        max_entries=100,
        now=lambda: 100 + 86_401,
    )

    # Then
    assert expired_cache.get(_key()) is None


def test_cache_keeps_only_most_recent_entries(tmp_path: Path) -> None:
    # Given
    current_time = 100
    cache = TranscriptCache(
        tmp_path / "transcripts.db",
        max_age_days=30,
        max_entries=2,
        now=lambda: current_time,
    )
    cache.put(_key("message-1"), _entry("one"))
    current_time = 101
    cache.put(_key("message-2"), _entry("two"))

    # When
    current_time = 102
    cache.put(_key("message-3"), _entry("three"))

    # Then
    assert cache.get(_key("message-1")) is None
    assert cache.get(_key("message-2")) == _entry("two")
    assert cache.get(_key("message-3")) == _entry("three")
