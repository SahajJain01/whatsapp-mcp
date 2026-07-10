"""Tests for the voice-note transcription module.

These tests lock the public interface of `transcribe` so the MCP tool
`transcribe_audio` can be wired up in `main.py` with confidence. Heavy
provider deps (`faster_whisper`, `openai`) are mocked via monkeypatch +
`sys.modules` injection so the suite runs without the wheels installed.
"""

from __future__ import annotations

import sys
import types
from unittest.mock import MagicMock

import pytest

import transcribe


# --- is_audio_media_type ----------------------------------------------------


@pytest.mark.parametrize(
    "value,expected",
    [
        ("audio", True),
        ("AUDIO", True),
        ("ptt", True),
        ("PTT", True),
        (" audio ", True),
        ("image", False),
        ("video", False),
        ("document", False),
        (None, False),
        ("", False),
    ],
)
def test_is_audio_media_type(value, expected):
    assert transcribe.is_audio_media_type(value) is expected


# --- transcribe_message -----------------------------------------------------


def test_transcribe_message_rejects_missing(monkeypatch):
    monkeypatch.setattr(transcribe, "get_message_media_type", lambda *_: None)
    result = transcribe.transcribe_message("m1", "c1@s.whatsapp.net")
    assert result["success"] is False
    assert result["message_id"] == "m1"
    assert result["chat_jid"] == "c1@s.whatsapp.net"
    assert "not found" in result["message"].lower()
    assert result["transcript"] is None


def test_transcribe_message_rejects_non_audio(monkeypatch):
    """S2: non-audio messages get an exact, non-crashing error message."""
    monkeypatch.setattr(transcribe, "get_message_media_type", lambda *_: "image")
    result = transcribe.transcribe_message("m1", "c1@s.whatsapp.net")
    assert result["success"] is False
    assert result["message"] == "Message is not an audio message (media_type=image)"
    assert result["transcript"] is None


def test_transcribe_message_dispatches_to_file(monkeypatch):
    """Happy path (S1): media_type=audio → download → transcribe_audio_file."""
    monkeypatch.setattr(transcribe, "get_message_media_type", lambda *_: "audio")

    # Inject a fake `whatsapp` module so the inner `import whatsapp` in
    # transcribe_message picks it up instead of the real module.
    fake_whatsapp = types.ModuleType("whatsapp")
    fake_whatsapp.download_media = lambda *_: "C:/fake/voice.ogg"
    monkeypatch.setitem(sys.modules, "whatsapp", fake_whatsapp)

    sentinel = {
        "success": True,
        "transcript": "hello world",
        "language": "en",
        "duration_seconds": 1.2,
        "provider": "local",
        "model": "small",
        "message": "Transcribed via faster-whisper",
    }
    calls = []

    def fake_file(path, language=None):
        calls.append((path, language))
        return sentinel

    monkeypatch.setattr(transcribe, "transcribe_audio_file", fake_file)

    result = transcribe.transcribe_message("m1", "c1@s.whatsapp.net", language="en")

    assert calls == [("C:/fake/voice.ogg", "en")]
    assert result["success"] is True
    assert result["transcript"] == "hello world"
    assert result["message_id"] == "m1"
    assert result["chat_jid"] == "c1@s.whatsapp.net"
    assert result["file_path"] == "C:/fake/voice.ogg"


# --- _local_model singleton -------------------------------------------------


def test_local_model_singleton_cached(monkeypatch):
    """Model is instantiated at most once per env config (lru_cache)."""
    fake_module = types.ModuleType("faster_whisper")
    constructor = MagicMock(return_value=MagicMock(name="WhisperModel"))
    fake_module.WhisperModel = constructor
    monkeypatch.setitem(sys.modules, "faster_whisper", fake_module)

    transcribe._local_model.cache_clear()
    try:
        m1 = transcribe._local_model()
        m2 = transcribe._local_model()
        assert m1 is m2
        assert constructor.call_count == 1
    finally:
        # Clean up so a real load doesn't get cached for downstream tests.
        transcribe._local_model.cache_clear()


# --- provider selection -----------------------------------------------------


def test_provider_selection_dispatches_to_openai(monkeypatch):
    """S5: WHATSAPP_MCP_TRANSCRIBE_PROVIDER=openai routes to the OpenAI path."""
    local_calls: list = []
    openai_calls: list = []

    monkeypatch.setenv("WHATSAPP_MCP_TRANSCRIBE_PROVIDER", "openai")
    monkeypatch.setattr(
        transcribe,
        "_transcribe_local",
        lambda p, lang: (
            local_calls.append((p, lang))
            or {"success": True, "provider": "local"}
        ),
    )
    monkeypatch.setattr(
        transcribe,
        "_transcribe_openai",
        lambda p, lang: (
            openai_calls.append((p, lang))
            or {"success": True, "provider": "openai"}
        ),
    )

    result = transcribe.transcribe_audio_file("C:/fake.ogg", "en")

    assert local_calls == []
    assert openai_calls == [("C:/fake.ogg", "en")]
    assert result["provider"] == "openai"
