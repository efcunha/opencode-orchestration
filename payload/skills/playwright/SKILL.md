---
name: mcp-playwright
description: "playwright MCP — 21 tools. Use mavis mcp call to invoke."
---

# playwright

MCP server with 21 available tools.

## Usage

List tools:
```bash
mavis mcp playwright --list
```

Call a tool:
```bash
mavis mcp call playwright <tool-name> '{"param": "value"}'
```

Tool details:
```bash
mavis mcp playwright <tool-name> --help
```

## Tools

### browser_click

Perform click on a web page

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| element | string | no | Human-readable element description used to obtain permission to interact with the element |
| ref | string | yes | Exact target element reference from the page snapshot |
| doubleClick | boolean | no | Whether to perform a double click instead of a single click |
| button | string | no | Button to click, defaults to left |
| modifiers | array | no | Modifier keys to press |

**Example:**
```bash
mavis mcp call playwright browser_click '{"ref":"<ref>"}'
```

### browser_close

Close the page

**Example:**
```bash
mavis mcp call playwright browser_close '{}'
```

### browser_console_messages

Returns all console messages

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| level | string | yes | Level of the console messages to return. Each level includes the messages of more severe levels. Defaults to "info". |
| all | boolean | no | Return all console messages since the beginning of the session, not just since the last navigation. Defaults to false. |
| filename | string | no | Filename to save the console messages to. If not provided, messages are returned as text. |

**Example:**
```bash
mavis mcp call playwright browser_console_messages '{"level":"<level>"}'
```

### browser_drag

Perform drag and drop between two elements

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| startElement | string | yes | Human-readable source element description used to obtain the permission to interact with the element |
| startRef | string | yes | Exact source element reference from the page snapshot |
| endElement | string | yes | Human-readable target element description used to obtain the permission to interact with the element |
| endRef | string | yes | Exact target element reference from the page snapshot |

**Example:**
```bash
mavis mcp call playwright browser_drag '{"startElement":"<startElement>","startRef":"<startRef>","endElement":"<endElement>","endRef":"<endRef>"}'
```

### browser_evaluate

Evaluate JavaScript expression on page or element

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| function | string | yes | () => { /* code */ } or (element) => { /* code */ } when element is provided |
| element | string | no | Human-readable element description used to obtain permission to interact with the element |
| ref | string | no | Exact target element reference from the page snapshot |
| filename | string | no | Filename to save the result to. If not provided, result is returned as text. |

**Example:**
```bash
mavis mcp call playwright browser_evaluate '{"function":"<function>"}'
```

### browser_file_upload

Upload one or multiple files

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| paths | array | no | The absolute paths to the files to upload. Can be single file or multiple files. If omitted, file chooser is cancelled. |

**Example:**
```bash
mavis mcp call playwright browser_file_upload '{}'
```

### browser_fill_form

Fill multiple form fields

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| fields | array | yes | Fields to fill in |

**Example:**
```bash
mavis mcp call playwright browser_fill_form '{"fields":"<fields>"}'
```

### browser_handle_dialog

Handle a dialog

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| accept | boolean | yes | Whether to accept the dialog. |
| promptText | string | no | The text of the prompt in case of a prompt dialog. |

**Example:**
```bash
mavis mcp call playwright browser_handle_dialog '{"accept":"<accept>"}'
```

### browser_hover

Hover over element on page

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| element | string | no | Human-readable element description used to obtain permission to interact with the element |
| ref | string | yes | Exact target element reference from the page snapshot |

**Example:**
```bash
mavis mcp call playwright browser_hover '{"ref":"<ref>"}'
```

### browser_navigate

Navigate to a URL

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| url | string | yes | The URL to navigate to |

**Example:**
```bash
mavis mcp call playwright browser_navigate '{"url":"<url>"}'
```

### browser_navigate_back

Go back to the previous page in the history

**Example:**
```bash
mavis mcp call playwright browser_navigate_back '{}'
```

### browser_network_requests

Returns all network requests since loading the page

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| static | boolean | yes | Whether to include successful static resources like images, fonts, scripts, etc. Defaults to false. |
| requestBody | boolean | yes | Whether to include request body. Defaults to false. |
| requestHeaders | boolean | yes | Whether to include request headers. Defaults to false. |
| filter | string | no | Only return requests whose URL matches this regexp (e.g. "/api/.*user"). |
| filename | string | no | Filename to save the network requests to. If not provided, requests are returned as text. |

**Example:**
```bash
mavis mcp call playwright browser_network_requests '{"static":"<static>","requestBody":"<requestBody>","requestHeaders":"<requestHeaders>"}'
```

### browser_press_key

Press a key on the keyboard

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| key | string | yes | Name of the key to press or a character to generate, such as `ArrowLeft` or `a` |

**Example:**
```bash
mavis mcp call playwright browser_press_key '{"key":"<key>"}'
```

### browser_resize

Resize the browser window

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| width | number | yes | Width of the browser window |
| height | number | yes | Height of the browser window |

**Example:**
```bash
mavis mcp call playwright browser_resize '{"width":"<width>","height":"<height>"}'
```

### browser_run_code

Run Playwright code snippet

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| code | string | no | A JavaScript function containing Playwright code to execute. It will be invoked with a single argument, page, which you can use for any page interaction. For example: `async (page) => { await page.getByRole('button', { name: 'Submit' }).click(); return await page.title(); }` |
| filename | string | no | Load code from the specified file. If both code and filename are provided, code will be ignored. |

**Example:**
```bash
mavis mcp call playwright browser_run_code '{}'
```

### browser_select_option

Select an option in a dropdown

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| element | string | no | Human-readable element description used to obtain permission to interact with the element |
| ref | string | yes | Exact target element reference from the page snapshot |
| values | array | yes | Array of values to select in the dropdown. This can be a single value or multiple values. |

**Example:**
```bash
mavis mcp call playwright browser_select_option '{"ref":"<ref>","values":"<values>"}'
```

### browser_snapshot

Capture accessibility snapshot of the current page, this is better than screenshot

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| filename | string | no | Save snapshot to markdown file instead of returning it in the response. |
| depth | number | no | Limit the depth of the snapshot tree |

**Example:**
```bash
mavis mcp call playwright browser_snapshot '{}'
```

### browser_tabs

List, create, close, or select a browser tab.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| action | string | yes | Operation to perform |
| index | number | no | Tab index, used for close/select. If omitted for close, current tab is closed. |

**Example:**
```bash
mavis mcp call playwright browser_tabs '{"action":"<action>"}'
```

### browser_take_screenshot

Take a screenshot of the current page. You can't perform actions based on the screenshot, use browser_snapshot for actions.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| type | string | yes | Image format for the screenshot. Default is png. |
| filename | string | no | File name to save the screenshot to. Defaults to `page-{timestamp}.{png|jpeg}` if not specified. Prefer relative file names to stay within the output directory. |
| element | string | no | Human-readable element description used to obtain permission to screenshot the element. If not provided, the screenshot will be taken of viewport. If element is provided, ref must be provided too. |
| ref | string | no | Exact target element reference from the page snapshot. If not provided, the screenshot will be taken of viewport. If ref is provided, element must be provided too. |
| fullPage | boolean | no | When true, takes a screenshot of the full scrollable page, instead of the currently visible viewport. Cannot be used with element screenshots. |

**Example:**
```bash
mavis mcp call playwright browser_take_screenshot '{"type":"<type>"}'
```

### browser_type

Type text into editable element

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| element | string | no | Human-readable element description used to obtain permission to interact with the element |
| ref | string | yes | Exact target element reference from the page snapshot |
| text | string | yes | Text to type into the element |
| submit | boolean | no | Whether to submit entered text (press Enter after) |
| slowly | boolean | no | Whether to type one character at a time. Useful for triggering key handlers in the page. By default entire text is filled in at once. |

**Example:**
```bash
mavis mcp call playwright browser_type '{"ref":"<ref>","text":"<text>"}'
```

### browser_wait_for

Wait for text to appear or disappear or a specified time to pass

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| time | number | no | The time to wait in seconds |
| text | string | no | The text to wait for |
| textGone | string | no | The text to wait for to disappear |

**Example:**
```bash
mavis mcp call playwright browser_wait_for '{}'
```

