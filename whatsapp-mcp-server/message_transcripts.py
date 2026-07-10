from __future__ import annotations

import re
from collections.abc import Callable, Mapping

JsonScalar = str | int | float | bool | None
TranscribeMessage = Callable[[str, str], Mapping[str, JsonScalar]]

_AUDIO_MESSAGE_PATTERN = re.compile(
    r"\[(?:audio|ptt) - Message ID: (?P<message_id>[^\]]+) - "
    r"Chat JID: (?P<chat_jid>[^\]]+)\]",
    re.IGNORECASE,
)


def append_voice_note_transcripts(
    messages: str,
    transcribe_message: TranscribeMessage,
) -> str:
    output_lines: list[str] = []
    for line in messages.splitlines(keepends=True):
        output_lines.append(line)
        match = _AUDIO_MESSAGE_PATTERN.search(line)
        if not match:
            continue

        result = transcribe_message(
            match.group("message_id"),
            match.group("chat_jid"),
        )
        transcript = result.get("transcript")
        if result.get("success") is True and isinstance(transcript, str) and transcript:
            separator = "" if line.endswith("\n") else "\n"
            output_lines.append(f"{separator}Transcript: {transcript}\n")

    return "".join(output_lines)
