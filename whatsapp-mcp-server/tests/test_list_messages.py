from __future__ import annotations

import main


def test_list_messages_auto_transcribes_audio(monkeypatch):
    transcript_calls: list[tuple[str, str]] = []
    audio_message = (
        "[2026-07-10 09:00:00] Chat: Alice From: Bob: "
        "[audio - Message ID: msg-audio - Chat JID: chat-1@s.whatsapp.net] "
        "<Media omitted>\n"
    )

    monkeypatch.setattr(main, "whatsapp_list_messages", lambda **_: audio_message)

    def fake_transcribe(message_id: str, chat_jid: str):
        transcript_calls.append((message_id, chat_jid))
        return {"success": True, "transcript": "hello from voice note"}

    monkeypatch.setattr(main, "whatsapp_transcribe_message", fake_transcribe)

    result = main.list_messages(include_context=False)

    assert transcript_calls == [("msg-audio", "chat-1@s.whatsapp.net")]
    assert "Transcript: hello from voice note" in result


def test_list_messages_leaves_non_audio_messages_unchanged(monkeypatch):
    transcript_calls: list[tuple[str, str]] = []
    image_message = (
        "[2026-07-10 09:00:00] Chat: Alice From: Bob: "
        "[image - Message ID: msg-image - Chat JID: chat-1@s.whatsapp.net] "
        "<Media omitted>\n"
    )

    monkeypatch.setattr(main, "whatsapp_list_messages", lambda **_: image_message)
    monkeypatch.setattr(
        main,
        "whatsapp_transcribe_message",
        lambda message_id, chat_jid: transcript_calls.append((message_id, chat_jid)),
    )

    result = main.list_messages(include_context=False)

    assert result == image_message
    assert transcript_calls == []


def test_list_messages_forwards_existing_arguments(monkeypatch):
    forwarded: dict[str, str | int | bool | None] = {}

    def fake_list_messages(**kwargs):
        forwarded.update(kwargs)
        return "No messages to display."

    monkeypatch.setattr(main, "whatsapp_list_messages", fake_list_messages)

    result = main.list_messages(
        after="2026-07-01T00:00:00",
        before="2026-07-10T00:00:00",
        sender_phone_number="12345",
        chat_jid="chat-1@s.whatsapp.net",
        query="hello",
        limit=5,
        page=2,
        include_context=False,
        context_before=3,
        context_after=4,
    )

    assert result == "No messages to display."
    assert forwarded == {
        "after": "2026-07-01T00:00:00",
        "before": "2026-07-10T00:00:00",
        "sender_phone_number": "12345",
        "chat_jid": "chat-1@s.whatsapp.net",
        "query": "hello",
        "limit": 5,
        "page": 2,
        "include_context": False,
        "context_before": 3,
        "context_after": 4,
    }
