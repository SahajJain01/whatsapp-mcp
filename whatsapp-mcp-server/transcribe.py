"""Voice-note transcription for the WhatsApp MCP server.

Provides a small provider abstraction so the LLM agent can get a text
transcript of a WhatsApp voice note / audio message via the
`transcribe_audio` MCP tool.

Default provider: `faster-whisper` (local, CPU int8, MIT). Uses bundled
PyAV, so no system ffmpeg is required for .ogg / Opus decoding.

Opt-in provider: OpenAI Whisper API. Enable with:

    WHATSAPP_MCP_TRANSCRIBE_PROVIDER=openai
    OPENAI_API_KEY=sk-...

Heavy imports (`faster_whisper`, `openai`) live inside the functions
that need them so the MCP process boots fast and the OpenAI extra can
be added lazily via `uv sync --extra openai`.
"""

from __future__ import annotations

import os
import os.path
import sqlite3
from functools import lru_cache
from pathlib import Path
from typing import Any, Dict, Optional

from transcript_cache import CacheEntry, CacheKey, TranscriptCache

# Same path derivation as whatsapp.py so both modules stay in sync.
MESSAGES_DB_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "whatsapp-bridge",
    "store",
    "messages.db",
)
TRANSCRIPT_CACHE_PATH = Path(MESSAGES_DB_PATH).with_name("transcripts.db")

# WhatsApp media_type strings that represent audio we can transcribe.
# "audio" is what the current Go bridge emits; "ptt" is a plausible future
# value for push-to-talk voice notes and is accepted defensively.
_AUDIO_MEDIA_TYPES = frozenset({"audio", "ptt"})


def is_audio_media_type(media_type: Optional[str]) -> bool:
    """Return True if `media_type` represents transcribable audio."""
    if not media_type:
        return False
    return media_type.strip().lower() in _AUDIO_MEDIA_TYPES


def get_message_media_type(message_id: str, chat_jid: str) -> Optional[str]:
    """Look up media_type for a message from the local SQLite store.

    Returns None if the message is not found or the database is unavailable.
    """
    try:
        conn = sqlite3.connect(MESSAGES_DB_PATH)
    except sqlite3.Error:
        return None
    try:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT media_type FROM messages WHERE id = ? AND chat_jid = ?",
            (message_id, chat_jid),
        )
        row = cursor.fetchone()
    except sqlite3.Error:
        return None
    finally:
        conn.close()

    if not row:
        return None
    return row[0]


# --- Provider config helpers ------------------------------------------------


def _provider() -> str:
    return (os.environ.get("WHATSAPP_MCP_TRANSCRIBE_PROVIDER") or "local").strip().lower()


def _local_model_name() -> str:
    return (os.environ.get("WHATSAPP_MCP_WHISPER_MODEL") or "large-v3").strip()


def _local_device() -> str:
    return (os.environ.get("WHATSAPP_MCP_WHISPER_DEVICE") or "cpu").strip()


def _local_compute_type() -> str:
    return (os.environ.get("WHATSAPP_MCP_WHISPER_COMPUTE_TYPE") or "int8").strip()


def _openai_model() -> str:
    return (os.environ.get("WHATSAPP_MCP_OPENAI_MODEL") or "whisper-1").strip()


def _active_model_name() -> str:
    return _openai_model() if _provider() == "openai" else _local_model_name()


# --- Local provider (faster-whisper) ---------------------------------------


@lru_cache(maxsize=1)
def _local_model():
    """Load and cache the faster-whisper model for the current env config.

    Heavy import lives inside so the MCP process starts fast and users
    who only want the OpenAI provider don't pay the import cost.
    """
    from faster_whisper import WhisperModel  # noqa: PLC0415 - lazy import

    return WhisperModel(
        _local_model_name(),
        device=_local_device(),
        compute_type=_local_compute_type(),
    )


def _transcribe_local(file_path: str, language: Optional[str]) -> Dict[str, Any]:
    model = _local_model()
    segments, info = model.transcribe(
        file_path,
        language=language,
        vad_filter=True,
    )
    # `segments` is a generator; materialize into text.
    text_parts = [seg.text for seg in segments]
    transcript = "".join(text_parts).strip()

    return {
        "success": True,
        "transcript": transcript,
        "language": getattr(info, "language", None),
        "duration_seconds": getattr(info, "duration", None),
        "provider": "local",
        "model": _local_model_name(),
        "message": "Transcribed via faster-whisper",
    }


# --- OpenAI provider --------------------------------------------------------


def _transcribe_openai(file_path: str, language: Optional[str]) -> Dict[str, Any]:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        return {
            "success": False,
            "transcript": None,
            "language": language,
            "duration_seconds": None,
            "provider": "openai",
            "model": _openai_model(),
            "message": (
                "OPENAI_API_KEY not set (required for "
                "WHATSAPP_MCP_TRANSCRIBE_PROVIDER=openai)"
            ),
        }

    from openai import OpenAI  # noqa: PLC0415 - lazy import (opt-in extra)

    client = OpenAI(api_key=api_key)
    with open(file_path, "rb") as fh:
        kwargs: Dict[str, Any] = {"model": _openai_model(), "file": fh}
        if language:
            kwargs["language"] = language
        result = client.audio.transcriptions.create(**kwargs)

    # The SDK returns a pydantic-like object with a .text attribute; be
    # defensive so tests can mock with a plain dict.
    text = getattr(result, "text", None)
    if text is None and isinstance(result, dict):
        text = result.get("text")
    transcript = text.strip() if isinstance(text, str) else None

    return {
        "success": True,
        "transcript": transcript,
        "language": language,
        "duration_seconds": None,
        "provider": "openai",
        "model": _openai_model(),
        "message": "Transcribed via OpenAI Whisper API",
    }


# --- Public API -------------------------------------------------------------


def transcribe_audio_file(
    file_path: str, language: Optional[str] = None
) -> Dict[str, Any]:
    """Transcribe an audio file on disk.

    Never raises. Returns a JSON-serialisable status dict. Dispatches to the
    provider selected by WHATSAPP_MCP_TRANSCRIBE_PROVIDER (default `local`).
    """
    provider = _provider()
    try:
        if provider == "openai":
            return _transcribe_openai(file_path, language)
        # Default provider: local faster-whisper.
        return _transcribe_local(file_path, language)
    except Exception as exc:  # noqa: BLE001 - MCP tool must not raise
        return {
            "success": False,
            "transcript": None,
            "language": language,
            "duration_seconds": None,
            "provider": provider,
            "model": _active_model_name(),
            "message": f"Transcription failed ({provider}): {exc}",
        }


def transcribe_message(
    message_id: str,
    chat_jid: str,
    language: Optional[str] = None,
) -> Dict[str, Any]:
    """Download + transcribe the audio for a WhatsApp message.

    Never raises. Returns a JSON-serialisable status dict shaped like:

        {
          "success": bool,
          "message_id": str,
          "chat_jid": str,
          "transcript": str | None,
          "language": str | None,
          "duration_seconds": float | None,
          "provider": "local" | "openai",
          "model": str,
          "message": str,
          "file_path": str,   # present only on a successful download path
        }
    """
    base: Dict[str, Any] = {"message_id": message_id, "chat_jid": chat_jid}

    media_type = get_message_media_type(message_id, chat_jid)
    if media_type is None:
        return {
            **base,
            "success": False,
            "transcript": None,
            "language": None,
            "duration_seconds": None,
            "provider": _provider(),
            "model": _active_model_name(),
            "message": "Message not found in local store",
        }
    if not is_audio_media_type(media_type):
        return {
            **base,
            "success": False,
            "transcript": None,
            "language": None,
            "duration_seconds": None,
            "provider": _provider(),
            "model": _active_model_name(),
            "message": (
                f"Message is not an audio message (media_type={media_type})"
            ),
        }

    provider = _provider()
    model = _active_model_name()
    cache_key = CacheKey(
        message_id=message_id,
        chat_jid=chat_jid,
        provider=provider,
        model=model,
        language_hint=language or "",
    )
    cache = TranscriptCache.from_environment(TRANSCRIPT_CACHE_PATH)
    cached = cache.get(cache_key)
    if cached is not None:
        return {**base, **cached.as_result(cache_key)}

    # Reuse the existing download pipeline. Local import avoids a hard cycle
    # (whatsapp.py doesn't import this module today, but keeping it local
    # also lets the tests inject a fake `whatsapp` module via sys.modules).
    import whatsapp  # noqa: PLC0415

    file_path = whatsapp.download_media(message_id, chat_jid)
    if not file_path:
        return {
            **base,
            "success": False,
            "transcript": None,
            "language": None,
            "duration_seconds": None,
            "provider": _provider(),
            "model": _active_model_name(),
            "message": "Failed to download media from WhatsApp bridge",
        }

    result = transcribe_audio_file(file_path, language)
    transcript = result.get("transcript")
    if result.get("success") is True and isinstance(transcript, str):
        detected_language = result.get("language")
        duration_seconds = result.get("duration_seconds")
        cache.put(
            cache_key,
            CacheEntry(
                transcript=transcript,
                detected_language=(
                    detected_language if isinstance(detected_language, str) else None
                ),
                duration_seconds=(
                    float(duration_seconds)
                    if isinstance(duration_seconds, (int, float))
                    else None
                ),
            ),
        )
    return {**base, **result, "file_path": file_path, "cached": False}
