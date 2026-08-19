---
name: mcp-trash
description: "trash MCP — 1 tools. Use mavis mcp call to invoke."
---

# trash

MCP server with 1 available tools.

## Usage

List tools:
```bash
mavis mcp trash --list
```

Call a tool:
```bash
mavis mcp call trash <tool-name> '{"param": "value"}'
```

Tool details:
```bash
mavis mcp trash <tool-name> --help
```

## Tools

### trash

Move files or directories to a recoverable trash bin. ALWAYS prefer this over `rm` — `rm` is irreversible without the daemon's safety net. Supported on macOS (Finder Trash), Linux (gio trash / freedesktop spec), and Windows (Recycle Bin). Items can be restored from the OS trash UI on supported platforms.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| paths | array | yes | Absolute or working-directory-relative paths to move to the trash. |

**Example:**
```bash
mavis mcp call trash trash '{"paths":"<paths>"}'
```

