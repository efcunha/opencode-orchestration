---
name: mcp-memory
description: "memory MCP — 9 tools. Use mavis mcp call to invoke."
---

# memory

MCP server with 9 available tools.

## Usage

List tools:
```bash
mavis mcp memory --list
```

Call a tool:
```bash
mavis mcp call memory <tool-name> '{"param": "value"}'
```

Tool details:
```bash
mavis mcp memory <tool-name> --help
```

## Tools

### add_observations

Add new observations to existing entities in the knowledge graph

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| observations | array | yes |  |

**Example:**
```bash
mavis mcp call memory add_observations '{"observations":"<observations>"}'
```

### create_entities

Create multiple new entities in the knowledge graph

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| entities | array | yes |  |

**Example:**
```bash
mavis mcp call memory create_entities '{"entities":"<entities>"}'
```

### create_relations

Create multiple new relations between entities in the knowledge graph. Relations should be in active voice

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| relations | array | yes |  |

**Example:**
```bash
mavis mcp call memory create_relations '{"relations":"<relations>"}'
```

### delete_entities

Delete multiple entities and their associated relations from the knowledge graph

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| entityNames | array | yes | An array of entity names to delete |

**Example:**
```bash
mavis mcp call memory delete_entities '{"entityNames":"<entityNames>"}'
```

### delete_observations

Delete specific observations from entities in the knowledge graph

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| deletions | array | yes |  |

**Example:**
```bash
mavis mcp call memory delete_observations '{"deletions":"<deletions>"}'
```

### delete_relations

Delete multiple relations from the knowledge graph

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| relations | array | yes | An array of relations to delete |

**Example:**
```bash
mavis mcp call memory delete_relations '{"relations":"<relations>"}'
```

### open_nodes

Open specific nodes in the knowledge graph by their names

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| names | array | yes | An array of entity names to retrieve |

**Example:**
```bash
mavis mcp call memory open_nodes '{"names":"<names>"}'
```

### read_graph

Read the entire knowledge graph

**Example:**
```bash
mavis mcp call memory read_graph '{}'
```

### search_nodes

Search for nodes in the knowledge graph based on a query

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| query | string | yes | The search query to match against entity names, types, and observation content |

**Example:**
```bash
mavis mcp call memory search_nodes '{"query":"<query>"}'
```

