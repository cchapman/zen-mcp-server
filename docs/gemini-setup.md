# Gemini CLI Setup

> **Note**: While PAL MCP Server connects successfully to Gemini CLI, tool invocation is not working
> correctly yet. We'll update this guide once the integration is fully functional.

This guide explains how to configure PAL MCP Server to work with [Gemini CLI](https://github.com/google-gemini/gemini-cli).

## Authentication

The Gemini provider supports two authentication methods:

### Method A: API Key (default)
1. Visit [Google AI Studio](https://makersuite.google.com/app/apikey)
2. Generate an API key
3. Set `GEMINI_API_KEY` in your `.env` file or MCP config

### Method B: Application Default Credentials (ADC)
Use your existing Google Cloud credentials — no API key needed.

**Local development:**
```bash
gcloud auth application-default login
```
Then leave `GEMINI_API_KEY` empty or remove it from your `.env` file. The server auto-detects ADC.

**GCP environments (Cloud Run, GKE, Compute Engine):**
ADC is automatic via the attached service account. No configuration needed — just don't set `GEMINI_API_KEY`.

**How it works:** The server checks for `GEMINI_API_KEY` first. If not found, it calls `google.auth.default()` to look for ADC credentials in this order:
1. `GOOGLE_APPLICATION_CREDENTIALS` environment variable
2. gcloud CLI credentials (`~/.config/gcloud/application_default_credentials.json`)
3. GCE/Cloud Run metadata server

Billing goes to whichever GCP project your ADC credentials are scoped to.

## Prerequisites

- PAL MCP Server installed and configured
- Gemini CLI installed
- At least one API key or ADC configured

## Configuration

1. Edit `~/.gemini/settings.json` and add:

```json
{
  "mcpServers": {
    "pal": {
      "command": "/path/to/pal-mcp-server/pal-mcp-server"
    }
  }
}
```

2. Replace `/path/to/pal-mcp-server` with your actual PAL MCP installation path (the folder name may still be `pal-mcp-server`).

3. If the `pal-mcp-server` wrapper script doesn't exist, create it:

```bash
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
exec .pal_venv/bin/python server.py "$@"
```

Then make it executable: `chmod +x pal-mcp-server`

4. Restart Gemini CLI.

All 15 PAL tools are now available in your Gemini CLI session.
