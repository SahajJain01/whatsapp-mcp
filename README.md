# WhatsApp MCP Server

This is a Model Context Protocol (MCP) server for WhatsApp.

With this you can search and read your personal Whatsapp messages (including images, videos, documents, and audio messages), search your contacts and send messages to either individuals or groups. You can also send media files including images, videos, documents, and audio messages.

It connects to your **personal WhatsApp account** directly via the Whatsapp web multidevice API (using the [whatsmeow](https://github.com/tulir/whatsmeow) library). All your messages are stored locally in a SQLite database and only sent to an LLM (such as Claude) when the agent accesses them through tools (which you control).

Here's an example of what you can do when it's connected to Claude.

![WhatsApp MCP](./example-use.png)

> To get updates on this and other projects I work on [enter your email here](https://docs.google.com/forms/d/1rTF9wMBTN0vPfzWuQa2BjfGKdKIpTbyeKxhPMcEzgyI/preview)

> *Caution:* as with many MCP servers, the WhatsApp MCP is subject to [the lethal trifecta](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/). This means that project injection could lead to private data exfiltration.

## Quick setup on Windows (automated)

If you're on Windows (including a KVM/QEMU VM like this fork was set up on), you can skip the manual steps below and run the bundled script:

```powershell
git clone https://github.com/<your-account>/whatsapp-mcp.git
cd whatsapp-mcp
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

`setup.ps1` is idempotent and does everything:

- Installs **Go**, **MSYS2 + GCC**, **uv**, and **FFmpeg** via `winget` (skips any already present)
- Copies the application to `%USERPROFILE%\mcp\whatsapp-mcp` and builds `whatsapp-bridge.exe` there
- Runs `uv sync` and prepares the local Whisper `large-v3` model
- Registers a hidden supervised task (`WhatsAppMCPBridge`) that restarts the bridge after failures and starts it after every Windows sign-in
- Prompts you to configure **Codex**, **Claude Desktop**, **OpenCode**, any combination of them, or none
- Opens a window **once** to scan the WhatsApp QR code (only the first time)
- Registers **WhatsApp MCP** in Windows Installed apps with an uninstaller beside the bridge binary

After it finishes, restart the MCP client(s) you selected and try *"search my WhatsApp contacts"*.

### Managing the hidden bridge

- **Stop:** `Stop-ScheduledTask -TaskName WhatsAppMCPBridge; Get-Process whatsapp-bridge | Stop-Process`
- **Disable auto-start:** `Disable-ScheduledTask -TaskName WhatsAppMCPBridge`
- **Re-authenticate:** run `%USERPROFILE%\mcp\whatsapp-mcp\whatsapp-bridge\run-bridge.ps1`, scan the QR, then start the task again.
- **Uninstall:** use Windows Settings > Apps > Installed apps > WhatsApp MCP, or run `%USERPROFILE%\mcp\whatsapp-mcp\whatsapp-bridge\uninstall.ps1`.

### Network workaround baked into the bridge

This fork's `whatsapp-bridge/main.go` includes a fix for hosts (notably some VMs) where the default WhatsApp connection hangs:

- Forces **IPv4** (the IPv6 path on these hosts accepts the TCP connection but drops data)
- Forces **HTTP/1.1** (HTTP/2's larger TLS handshake gets black-holed)
- **Retries the TLS handshake** (the first handshake to a new host is silently dropped and times out at ~15s; a retry succeeds in <100ms)

You'll see one `TLS handshake failed (attempt 1), retrying` warning on startup — that's expected and harmless. On a normal network these workarounds are no-ops.

It also upgrades `whatsmeow` to a current version (the original pin was rejected by WhatsApp with a `405 Client outdated` error).

### Optional: fix the networking for *all* apps (VirtIO VMs)

The bridge workaround above only fixes the bridge. If the **whole VM** has flaky TLS (Microsoft Store stuck on "checking dependencies", HTTP/2 hanging, `gh`/Go tools timing out), the cause is usually a VirtIO NIC hardware-offload bug on the host. Fix it system-wide with:

```powershell
powershell -ExecutionPolicy Bypass -File .\fix-vm-networking.ps1
```

This disables NIC offloads (LSO/RSC/checksum), lowers the MTU, and turns off a few TCP features that trigger the bug. It's persistent across reboots and reversible (revert block is at the bottom of the script). Run it elevated.

## Installation

### Prerequisites

- Go
- Python 3.6+
- Anthropic Claude Desktop app (or Cursor)
- UV (Python package manager), install with `curl -LsSf https://astral.sh/uv/install.sh | sh`
- FFmpeg (_optional_) - Only needed for audio messages. If you want to send audio files as playable WhatsApp voice messages, they must be in `.ogg` Opus format. With FFmpeg installed, the MCP server will automatically convert non-Opus audio files. Without FFmpeg, you can still send raw audio files using the `send_file` tool.

### Steps

1. **Clone this repository**

   ```bash
   git clone https://github.com/lharries/whatsapp-mcp.git
   cd whatsapp-mcp
   ```

2. **Run the WhatsApp bridge**

   Navigate to the whatsapp-bridge directory and run the Go application:

   ```bash
   cd whatsapp-bridge
   go run main.go
   ```

   The first time you run it, you will be prompted to scan a QR code. Scan the QR code with your WhatsApp mobile app to authenticate.

   After approximately 20 days, you will might need to re-authenticate.

3. **Connect to the MCP server**

   Copy the below json with the appropriate {{PATH}} values:

   ```json
   {
     "mcpServers": {
       "whatsapp": {
         "command": "{{PATH_TO_UV}}", // Run `which uv` and place the output here
         "args": [
           "--directory",
           "{{PATH_TO_SRC}}/whatsapp-mcp/whatsapp-mcp-server", // cd into the repo, run `pwd` and enter the output here + "/whatsapp-mcp-server"
           "run",
           "main.py"
         ]
       }
     }
   }
   ```

   For **Claude**, save this as `claude_desktop_config.json` in your Claude Desktop configuration directory at:

   ```
   ~/Library/Application Support/Claude/claude_desktop_config.json
   ```

   For **Cursor**, save this as `mcp.json` in your Cursor configuration directory at:

   ```
   ~/.cursor/mcp.json
   ```

   For **opencode** (global config), edit `~/.config/opencode/opencode.json` (Windows: `%USERPROFILE%\.config\opencode\opencode.json`) and merge in an `mcp` block:

   ```json
   {
     "mcp": {
       "whatsapp": {
         "type": "local",
         "command": ["uv", "run", "main.py"],
         "cwd": "{{PATH_TO_SRC}}/whatsapp-mcp/whatsapp-mcp-server",
         "enabled": true
       }
     }
   }
   ```

   Then restart opencode — it does not hot-reload MCP config. On Windows, `setup.ps1` writes this file for you automatically.

4. **Restart Claude Desktop / Cursor / opencode**

   Open Claude Desktop and you should now see WhatsApp as an available integration.

   Or restart Cursor.

### Windows Compatibility

If you're running this project on Windows, be aware that `go-sqlite3` requires **CGO to be enabled** in order to compile and work properly. By default, **CGO is disabled on Windows**, so you need to explicitly enable it and have a C compiler installed.

#### Steps to get it working:

1. **Install a C compiler**  
   We recommend using [MSYS2](https://www.msys2.org/) to install a C compiler for Windows. After installing MSYS2, make sure to add the `ucrt64\bin` folder to your `PATH`.  
   → A step-by-step guide is available [here](https://code.visualstudio.com/docs/cpp/config-mingw).

2. **Enable CGO and run the app**

   ```bash
   cd whatsapp-bridge
   go env -w CGO_ENABLED=1
   go run main.go
   ```

Without this setup, you'll likely run into errors like:

> `Binary was compiled with 'CGO_ENABLED=0', go-sqlite3 requires cgo to work.`

## Architecture Overview

This application consists of two main components:

1. **Go WhatsApp Bridge** (`whatsapp-bridge/`): A Go application that connects to WhatsApp's web API, handles authentication via QR code, and stores message history in SQLite. It serves as the bridge between WhatsApp and the MCP server.

2. **Python MCP Server** (`whatsapp-mcp-server/`): A Python server implementing the Model Context Protocol (MCP), which provides standardized tools for Claude to interact with WhatsApp data and send/receive messages.

### Data Storage

- All message history is stored in a SQLite database within the `whatsapp-bridge/store/` directory
- The database maintains tables for chats and messages
- Messages are indexed for efficient searching and retrieval

## Usage

Once connected, you can interact with your WhatsApp contacts through Claude, leveraging Claude's AI capabilities in your WhatsApp conversations.

### MCP Tools

Claude can access the following tools to interact with WhatsApp:

- **search_contacts**: Search for contacts by name or phone number
- **list_messages**: Retrieve messages with optional filters and context
- **list_chats**: List available chats with metadata
- **get_chat**: Get information about a specific chat
- **get_direct_chat_by_contact**: Find a direct chat with a specific contact
- **get_contact_chats**: List all chats involving a specific contact
- **get_last_interaction**: Get the most recent message with a contact
- **get_message_context**: Retrieve context around a specific message
- **send_message**: Send a WhatsApp message to a specified phone number or group JID
- **send_file**: Send a file (image, video, raw audio, document) to a specified recipient
- **send_audio_message**: Send an audio file as a WhatsApp voice message (requires the file to be an .ogg opus file or ffmpeg must be installed)
- **download_media**: Download media from a WhatsApp message and get the local file path
- **transcribe_audio**: Transcribe a WhatsApp voice note or audio message and return the text plus detected language

### Media Handling Features

The MCP server supports both sending and receiving various media types:

#### Media Sending

You can send various media types to your WhatsApp contacts:

- **Images, Videos, Documents**: Use the `send_file` tool to share any supported media type.
- **Voice Messages**: Use the `send_audio_message` tool to send audio files as playable WhatsApp voice messages.
  - For optimal compatibility, audio files should be in `.ogg` Opus format.
  - With FFmpeg installed, the system will automatically convert other audio formats (MP3, WAV, etc.) to the required format.
  - Without FFmpeg, you can still send raw audio files using the `send_file` tool, but they won't appear as playable voice messages.

#### Media Downloading

By default, just the metadata of the media is stored in the local database. The message will indicate that media was sent. To access this media you need to use the download_media tool which takes the `message_id` and `chat_jid` (which are shown when printing messages containing the meda), this downloads the media and then returns the file path which can be then opened or passed to another tool.

#### Voice Note Transcription

`list_messages` automatically returns a transcript directly below every voice note or audio message. The transcript is persisted locally, so later tool calls reuse it without downloading or transcribing the audio again. `transcribe_audio(message_id, chat_jid, language=None)` remains available for direct requests.

Providers (selected by the `WHATSAPP_MCP_TRANSCRIBE_PROVIDER` env var):

- **`local` (default)**: [`faster-whisper`](https://github.com/SYSTRAN/faster-whisper) on CPU (`int8`) with the `large-v3` model. Windows setup downloads the model during installation. Decoding uses bundled PyAV, so **no system ffmpeg is required** for transcription.
- **`openai`**: OpenAI Whisper API. Requires `OPENAI_API_KEY` and installing the extra: `uv sync --extra openai`.

Configuration:

| Variable | Default | Notes |
|---|---|---|
| `WHATSAPP_MCP_TRANSCRIBE_PROVIDER` | `local` | `local` \| `openai` |
| `WHATSAPP_MCP_WHISPER_MODEL` | `large-v3` | `tiny` \| `base` \| `small` \| `medium` \| `large-v3` |
| `WHATSAPP_MCP_WHISPER_DEVICE` | `cpu` | `cpu` \| `cuda` |
| `WHATSAPP_MCP_WHISPER_COMPUTE_TYPE` | `int8` | `int8` \| `float16` \| `float32` |
| `WHATSAPP_MCP_OPENAI_MODEL` | `whisper-1` | OpenAI-side model id |
| `OPENAI_API_KEY` | _unset_ | required when `PROVIDER=openai` |
| `WHATSAPP_MCP_TRANSCRIPT_CACHE_DAYS` | `30` | Remove entries not used within this many days |
| `WHATSAPP_MCP_TRANSCRIPT_CACHE_MAX_ENTRIES` | `1000` | Keep only the most recently used transcripts; set `0` to disable caching |

Non-audio messages return `{"success": false, "message": "Message is not an audio message (media_type=<type>)"}` without raising.

## Technical Details

1. Claude sends requests to the Python MCP server
2. The MCP server queries the Go bridge for WhatsApp data or directly to the SQLite database
3. The Go accesses the WhatsApp API and keeps the SQLite database up to date
4. Data flows back through the chain to Claude
5. When sending messages, the request flows from Claude through the MCP server to the Go bridge and to WhatsApp

## Troubleshooting

- If you encounter permission issues when running uv, you may need to add it to your PATH or use the full path to the executable.
- Make sure both the Go application and the Python server are running for the integration to work properly.

### Authentication Issues

- **QR Code Not Displaying**: If the QR code doesn't appear, try restarting the authentication script. If issues persist, check if your terminal supports displaying QR codes.
- **WhatsApp Already Logged In**: If your session is already active, the Go bridge will automatically reconnect without showing a QR code.
- **Device Limit Reached**: WhatsApp limits the number of linked devices. If you reach this limit, you'll need to remove an existing device from WhatsApp on your phone (Settings > Linked Devices).
- **No Messages Loading**: After initial authentication, it can take several minutes for your message history to load, especially if you have many chats.
- **WhatsApp Out of Sync**: If your WhatsApp messages get out of sync with the bridge, delete both database files (`whatsapp-bridge/store/messages.db` and `whatsapp-bridge/store/whatsapp.db`) and restart the bridge to re-authenticate.

For additional Claude Desktop integration troubleshooting, see the [MCP documentation](https://modelcontextprotocol.io/quickstart/server#claude-for-desktop-integration-issues). The documentation includes helpful tips for checking logs and resolving common issues.
