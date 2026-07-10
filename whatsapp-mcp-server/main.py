import base64
import json
import mimetypes
from pathlib import Path
from typing import List, Dict, Any, Optional
from urllib.parse import quote, unquote

from mcp.server.fastmcp import FastMCP
from mcp.types import BlobResourceContents, EmbeddedResource, ImageContent, TextContent
from whatsapp import (
    search_contacts as whatsapp_search_contacts,
    list_messages as whatsapp_list_messages,
    list_chats as whatsapp_list_chats,
    get_chat as whatsapp_get_chat,
    get_direct_chat_by_contact as whatsapp_get_direct_chat_by_contact,
    get_contact_chats as whatsapp_get_contact_chats,
    get_last_interaction as whatsapp_get_last_interaction,
    get_message_context as whatsapp_get_message_context,
    send_message as whatsapp_send_message,
    send_file as whatsapp_send_file,
    send_audio_message as whatsapp_audio_voice_message,
    download_media as whatsapp_download_media
)
from transcribe import transcribe_message as whatsapp_transcribe_message

# Initialize FastMCP server
mcp = FastMCP("whatsapp")

DEFAULT_MAX_INLINE_MEDIA_BYTES = 8 * 1024 * 1024


def _media_resource_uri(message_id: str, chat_jid: str) -> str:
    return f"whatsapp-media://{quote(chat_jid, safe='')}/{quote(message_id, safe='')}"


def _guess_media_mime_type(file_path: str) -> str:
    mime_type, _ = mimetypes.guess_type(file_path)
    return mime_type or "application/octet-stream"


def _build_media_metadata(message_id: str, chat_jid: str, file_path: str) -> Dict[str, Any]:
    path = Path(file_path)
    return {
        "success": True,
        "message": "Media downloaded successfully",
        "message_id": message_id,
        "chat_jid": chat_jid,
        "file_path": str(path),
        "filename": path.name,
        "mime_type": _guess_media_mime_type(str(path)),
        "size_bytes": path.stat().st_size,
        "resource_uri": _media_resource_uri(message_id, chat_jid),
    }


@mcp.resource(
    "whatsapp-media://{chat_jid}/{message_id}",
    name="WhatsApp media",
    description="Downloaded WhatsApp media content for a message",
    mime_type="application/octet-stream",
)
def get_media_resource(chat_jid: str, message_id: str) -> bytes:
    """Read downloaded WhatsApp media bytes for clients that support MCP resources."""
    decoded_chat_jid = unquote(chat_jid)
    decoded_message_id = unquote(message_id)
    file_path = whatsapp_download_media(decoded_message_id, decoded_chat_jid)

    if not file_path:
        raise FileNotFoundError("Media could not be downloaded")

    return Path(file_path).read_bytes()


@mcp.tool()
def search_contacts(query: str) -> List[Dict[str, Any]]:
    """Search WhatsApp contacts by name or phone number.
    
    Args:
        query: Search term to match against contact names or phone numbers
    """
    contacts = whatsapp_search_contacts(query)
    return contacts

@mcp.tool()
def list_messages(
    after: Optional[str] = None,
    before: Optional[str] = None,
    sender_phone_number: Optional[str] = None,
    chat_jid: Optional[str] = None,
    query: Optional[str] = None,
    limit: int = 20,
    page: int = 0,
    include_context: bool = True,
    context_before: int = 1,
    context_after: int = 1
) -> List[Dict[str, Any]]:
    """Get WhatsApp messages matching specified criteria with optional context.
    
    Args:
        after: Optional ISO-8601 formatted string to only return messages after this date
        before: Optional ISO-8601 formatted string to only return messages before this date
        sender_phone_number: Optional phone number to filter messages by sender
        chat_jid: Optional chat JID to filter messages by chat
        query: Optional search term to filter messages by content
        limit: Maximum number of messages to return (default 20)
        page: Page number for pagination (default 0)
        include_context: Whether to include messages before and after matches (default True)
        context_before: Number of messages to include before each match (default 1)
        context_after: Number of messages to include after each match (default 1)
    """
    messages = whatsapp_list_messages(
        after=after,
        before=before,
        sender_phone_number=sender_phone_number,
        chat_jid=chat_jid,
        query=query,
        limit=limit,
        page=page,
        include_context=include_context,
        context_before=context_before,
        context_after=context_after
    )
    return messages

@mcp.tool()
def list_chats(
    query: Optional[str] = None,
    limit: int = 20,
    page: int = 0,
    include_last_message: bool = True,
    sort_by: str = "last_active"
) -> List[Dict[str, Any]]:
    """Get WhatsApp chats matching specified criteria.
    
    Args:
        query: Optional search term to filter chats by name or JID
        limit: Maximum number of chats to return (default 20)
        page: Page number for pagination (default 0)
        include_last_message: Whether to include the last message in each chat (default True)
        sort_by: Field to sort results by, either "last_active" or "name" (default "last_active")
    """
    chats = whatsapp_list_chats(
        query=query,
        limit=limit,
        page=page,
        include_last_message=include_last_message,
        sort_by=sort_by
    )
    return chats

@mcp.tool()
def get_chat(chat_jid: str, include_last_message: bool = True) -> Dict[str, Any]:
    """Get WhatsApp chat metadata by JID.
    
    Args:
        chat_jid: The JID of the chat to retrieve
        include_last_message: Whether to include the last message (default True)
    """
    chat = whatsapp_get_chat(chat_jid, include_last_message)
    return chat

@mcp.tool()
def get_direct_chat_by_contact(sender_phone_number: str) -> Dict[str, Any]:
    """Get WhatsApp chat metadata by sender phone number.
    
    Args:
        sender_phone_number: The phone number to search for
    """
    chat = whatsapp_get_direct_chat_by_contact(sender_phone_number)
    return chat

@mcp.tool()
def get_contact_chats(jid: str, limit: int = 20, page: int = 0) -> List[Dict[str, Any]]:
    """Get all WhatsApp chats involving the contact.
    
    Args:
        jid: The contact's JID to search for
        limit: Maximum number of chats to return (default 20)
        page: Page number for pagination (default 0)
    """
    chats = whatsapp_get_contact_chats(jid, limit, page)
    return chats

@mcp.tool()
def get_last_interaction(jid: str) -> str:
    """Get most recent WhatsApp message involving the contact.
    
    Args:
        jid: The JID of the contact to search for
    """
    message = whatsapp_get_last_interaction(jid)
    return message

@mcp.tool()
def get_message_context(
    message_id: str,
    before: int = 5,
    after: int = 5
) -> Dict[str, Any]:
    """Get context around a specific WhatsApp message.
    
    Args:
        message_id: The ID of the message to get context for
        before: Number of messages to include before the target message (default 5)
        after: Number of messages to include after the target message (default 5)
    """
    context = whatsapp_get_message_context(message_id, before, after)
    return context

@mcp.tool()
def send_message(
    recipient: str,
    message: str
) -> Dict[str, Any]:
    """Send a WhatsApp message to a person or group. For group chats use the JID.

    Args:
        recipient: The recipient - either a phone number with country code but no + or other symbols,
                 or a JID (e.g., "123456789@s.whatsapp.net" or a group JID like "123456789@g.us")
        message: The message text to send
    
    Returns:
        A dictionary containing success status and a status message
    """
    # Validate input
    if not recipient:
        return {
            "success": False,
            "message": "Recipient must be provided"
        }
    
    # Call the whatsapp_send_message function with the unified recipient parameter
    success, status_message = whatsapp_send_message(recipient, message)
    return {
        "success": success,
        "message": status_message
    }

@mcp.tool()
def send_file(recipient: str, media_path: str) -> Dict[str, Any]:
    """Send a file such as a picture, raw audio, video or document via WhatsApp to the specified recipient. For group messages use the JID.
    
    Args:
        recipient: The recipient - either a phone number with country code but no + or other symbols,
                 or a JID (e.g., "123456789@s.whatsapp.net" or a group JID like "123456789@g.us")
        media_path: The absolute path to the media file to send (image, video, document)
    
    Returns:
        A dictionary containing success status and a status message
    """
    
    # Call the whatsapp_send_file function
    success, status_message = whatsapp_send_file(recipient, media_path)
    return {
        "success": success,
        "message": status_message
    }

@mcp.tool()
def send_audio_message(recipient: str, media_path: str) -> Dict[str, Any]:
    """Send any audio file as a WhatsApp audio message to the specified recipient. For group messages use the JID. If it errors due to ffmpeg not being installed, use send_file instead.
    
    Args:
        recipient: The recipient - either a phone number with country code but no + or other symbols,
                 or a JID (e.g., "123456789@s.whatsapp.net" or a group JID like "123456789@g.us")
        media_path: The absolute path to the audio file to send (will be converted to Opus .ogg if it's not a .ogg file)
    
    Returns:
        A dictionary containing success status and a status message
    """
    success, status_message = whatsapp_audio_voice_message(recipient, media_path)
    return {
        "success": success,
        "message": status_message
    }

@mcp.tool()
def download_media(
    message_id: str,
    chat_jid: str,
    include_data: bool = True,
    max_inline_bytes: int = DEFAULT_MAX_INLINE_MEDIA_BYTES
) -> List[Any]:
    """Download media from a WhatsApp message and return content clients can read.
    
    Args:
        message_id: The ID of the message containing the media
        chat_jid: The JID of the chat containing the message
        include_data: Whether to include the media bytes in the tool response when possible
        max_inline_bytes: Maximum file size to include inline in the tool response
    
    Returns:
        Metadata plus inline image/resource content when the downloaded file is small enough
    """
    file_path = whatsapp_download_media(message_id, chat_jid)
    
    if not file_path:
        return [
            TextContent(
                type="text",
                text=json.dumps({
                    "success": False,
                    "message": "Failed to download media"
                })
            )
        ]

    try:
        metadata = _build_media_metadata(message_id, chat_jid, file_path)
    except OSError as exc:
        return [
            TextContent(
                type="text",
                text=json.dumps({
                    "success": False,
                    "message": f"Media downloaded but could not be read: {exc}",
                    "file_path": file_path,
                })
            )
        ]

    content: List[Any] = [
        TextContent(type="text", text=json.dumps(metadata))
    ]

    if not include_data:
        return content

    if max_inline_bytes < 0:
        max_inline_bytes = 0

    if metadata["size_bytes"] > max_inline_bytes:
        content[0] = TextContent(
            type="text",
            text=json.dumps({
                **metadata,
                "inline_data_included": False,
                "inline_data_reason": (
                    f"File is {metadata['size_bytes']} bytes, above max_inline_bytes={max_inline_bytes}. "
                    "Read resource_uri to retrieve the bytes."
                )
            })
        )
        return content

    with open(file_path, "rb") as media_file:
        encoded_data = base64.b64encode(media_file.read()).decode("ascii")

    mime_type = metadata["mime_type"]
    content[0] = TextContent(
        type="text",
        text=json.dumps({
            **metadata,
            "inline_data_included": True,
            "data_base64": encoded_data,
        })
    )

    if mime_type.startswith("image/"):
        content.append(
            ImageContent(
                type="image",
                data=encoded_data,
                mimeType=mime_type,
            )
        )
    else:
        content.append(
            EmbeddedResource(
                type="resource",
                resource=BlobResourceContents(
                    uri=metadata["resource_uri"],
                    mimeType=mime_type,
                    blob=encoded_data,
                ),
            )
        )

    return content

@mcp.tool()
def transcribe_audio(
    message_id: str,
    chat_jid: str,
    language: Optional[str] = None
) -> Dict[str, Any]:
    """Transcribe a WhatsApp voice note or audio message and return the text.

    Downloads the media via the local WhatsApp bridge (if not already cached)
    and runs speech-to-text. The default provider is `faster-whisper`, which
    runs 100% locally on CPU (int8) and does not require a system `ffmpeg`
    install. To use the OpenAI Whisper API instead, set
    `WHATSAPP_MCP_TRANSCRIBE_PROVIDER=openai` and `OPENAI_API_KEY`, and install
    the extra via `uv sync --extra openai`.

    Args:
        message_id: The ID of the message containing the audio (same field
            you would pass to `download_media`).
        chat_jid: The JID of the chat containing the message.
        language: Optional ISO-639-1 language hint (e.g. "en", "es"). If
            omitted, the model auto-detects.

    Returns:
        A dictionary with `success`, `transcript`, `language`,
        `duration_seconds`, `provider`, `model`, and a human-readable
        `message`. For non-audio messages returns `success=false` with a
        descriptive `message` rather than raising.
    """
    return whatsapp_transcribe_message(message_id, chat_jid, language)

if __name__ == "__main__":
    # Initialize and run the server
    mcp.run(transport='stdio')
