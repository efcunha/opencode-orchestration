---
name: mcp-mcp-igniter
description: "mcp-igniter MCP — 49 tools. Use mavis mcp call to invoke."
---

# mcp-igniter

MCP server with 49 available tools.

## Usage

List tools:
```bash
mavis mcp mcp-igniter --list
```

Call a tool:
```bash
mavis mcp call mcp-igniter <tool-name> '{"param": "value"}'
```

Tool details:
```bash
mavis mcp mcp-igniter <tool-name> --help
```

## Tools

### add_package_dependency

Adds a new dependency to a project using the configured package manager (npm, yarn, bun).

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| package_name | string | yes | The name of the package to add (e.g., axios, lodash). |
| version | string | no | The specific version of the package (e.g., ^1.0.0, latest). Defaults to the latest version. |
| dev_dependency | boolean | no | If true, adds as a development dependency. |

**Example:**
```bash
mavis mcp call mcp-igniter add_package_dependency '{"package_name":"<package_name>"}'
```

### analyze_feature

Comprehensive analysis of a feature implementation including files, structure, errors, and API endpoints.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| featurePath | string | yes | Absolute path to feature directory or main file |
| projectRoot | string | yes | Project root for better analysis |
| includeStats | boolean | no | Include file statistics and metrics |

**Example:**
```bash
mavis mcp call mcp-igniter analyze_feature '{"featurePath":"<featurePath>","projectRoot":"<projectRoot>"}'
```

### analyze_file

Analyzes the structure, imports, exports, functions, and TypeScript errors of a file.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| filePath | string | yes | Absolute path to the file to analyze. |
| includeErrors | boolean | no | Include TypeScript and ESLint diagnostics |
| projectRoot | string | no | Project root for better TypeScript analysis |

**Example:**
```bash
mavis mcp call mcp-igniter analyze_file '{"filePath":"<filePath>"}'
```

### build_project

**What it does:** Compiles the project for production. This includes building the web framework and generating the final Igniter.js client.
**When to use:** Before deploying the application or when you need to test the production build locally.
**How it works:** Executes 'npm run build', which typically runs TypeScript compilation and framework-specific build commands.
**Result:** A production-ready build in the project's output directory (e.g., '.next' or 'dist').

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| mode | string | no | Build mode. 'production' is the default and standard for builds. |

**Example:**
```bash
mavis mcp call mcp-igniter build_project '{}'
```

### cancel_delegation

Cancel a running or queued delegation. Use when: stopping unnecessary agent work, freeing up resources, or correcting delegation mistakes. Only works on tasks that are currently queued or running.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| task_id | string | yes | ID of the task to cancel delegation |

**Example:**
```bash
mavis mcp call mcp-igniter cancel_delegation '{"task_id":"<task_id>"}'
```

### check_agent_environment

Verifies that all required tools and configurations are properly installed for agent task delegation. Use when: setting up the development environment, troubleshooting delegation issues, before starting delegation workflows, or during environment diagnostics. Checks Node.js version, Docker status, CLI availability, API key configuration, and agent provider readiness.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| check_docker | boolean | no | Verify Docker installation and daemon status |
| check_api_keys | boolean | no | Verify agent service API key configuration |
| check_models | boolean | no | Check available models for each agent type |
| detailed_report | boolean | no | Include detailed diagnostic information |
| debug_env | boolean | no | Enable debug output for environment variables |

**Example:**
```bash
mavis mcp call mcp-igniter check_agent_environment '{}'
```

### check_delegation_status

Check the current status of a delegated task, including progress, output, and execution details. Use when: monitoring background delegation progress, debugging execution issues, or getting real-time updates on agent work. Provides comprehensive status information for any delegated task.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| task_id | string | yes | ID of the task to check delegation status |

**Example:**
```bash
mavis mcp call mcp-igniter check_delegation_status '{"task_id":"<task_id>"}'
```

### close_github_issue

Closes an open GitHub issue

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| issueNumber | number | yes | The issue number to close |
| repository | string | no | Repository in format 'owner/repo'. Defaults to 'felipebarcelospro/igniter-js' |

**Example:**
```bash
mavis mcp call mcp-igniter close_github_issue '{"issueNumber":"<issueNumber>"}'
```

### create_github_issue

Create a new GitHub issue

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| title | string | yes | Issue title |
| body | string | yes | Issue body/description |
| repository | string | no | Repository in format 'owner/repo'. Defaults to 'felipebarcelospro/igniter-js' |
| labels | array | no | Labels to add to the issue |
| assignees | array | no | Users to assign to the issue |

**Example:**
```bash
mavis mcp call mcp-igniter create_github_issue '{"title":"<title>","body":"<body>"}'
```

### create_github_issue_comment

Adds a new comment to a GitHub issue

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| issueNumber | number | yes | The issue number to comment on |
| body | string | yes | The comment body |
| repository | string | no | Repository in format 'owner/repo'. Defaults to 'felipebarcelospro/igniter-js' |

**Example:**
```bash
mavis mcp call mcp-igniter create_github_issue_comment '{"issueNumber":"<issueNumber>","body":"<body>"}'
```

### create_task

Creates a new development task with full metadata, dependencies, and optional agent delegation configuration. Use when: planning new work items, breaking down features into actionable tasks, setting up development workflows. Supports task prioritization, assignee specification (human or agent), time estimation, and dependency management for comprehensive project tracking.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| title | string | yes | Clear, actionable task title |
| content | string | yes | Detailed task description with acceptance criteria |
| feature_id | string | no | Parent feature or epic ID |
| priority | string | no |  |
| assignee | string | no | Who should execute this task |
| estimated_hours | number | no | Estimated time to complete in hours |
| due_date | string | no | Target completion date (ISO format) |
| dependencies | array | no | Array of task IDs that must complete first |
| tags | array | no | Tags for categorization and filtering |
| context_files | array | no | Relevant files for task context |

**Example:**
```bash
mavis mcp call mcp-igniter create_task '{"title":"<title>","content":"<content>"}'
```

### delegate_to_agent

Delegates a development task to a specialized coding agent using secure background execution. Use when: task complexity requires focused agent attention, parallel execution is needed, specialized expertise is required (code review, research, implementation), or when Lia needs to focus on strategic work. Supports multiple agent types, sandbox isolation, background execution, and comprehensive progress monitoring. Tasks run in background - use check_delegation_status to monitor progress. Each agent uses its default model (no model selection available).

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| task_id | string | yes | ID of task to delegate |
| agent_type | string | yes | Type of agent to use for delegation |
| execution_mode | string | no | Execution mode: background (non-blocking) or sync (wait for completion) |
| execution_config | object | no |  |
| context | object | no |  |

**Example:**
```bash
mavis mcp call mcp-igniter delegate_to_agent '{"task_id":"<task_id>","agent_type":"<agent_type>"}'
```

### delete_github_issue_comment

Deletes a comment from a GitHub issue

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| commentId | number | yes | The comment ID to delete |
| repository | string | no | Repository in format 'owner/repo'. Defaults to 'felipebarcelospro/igniter-js' |

**Example:**
```bash
mavis mcp call mcp-igniter delete_github_issue_comment '{"commentId":"<commentId>"}'
```

### delete_task

Permanently removes a task from the system and handles dependent tasks appropriately. Use when: tasks become obsolete, requirements change, or duplicates are found. Provides options for handling dependent tasks: fail if dependencies exist, cascade delete, or unlink dependencies for manual review.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| task_id | string | yes | ID of the task to delete |
| handle_dependencies | string | no | How to handle tasks that depend on this one |

**Example:**
```bash
mavis mcp call mcp-igniter delete_task '{"task_id":"<task_id>"}'
```

### explore_source

Analyze implementation file with detailed focus on specific symbol and its context.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| filePath | string | yes | File to analyze |
| symbol | string | no | Specific symbol to focus on |
| includeContext | boolean | no | Include surrounding context and dependencies |

**Example:**
```bash
mavis mcp call mcp-igniter explore_source '{"filePath":"<filePath>"}'
```

### find_delegation_candidates

Identify tasks that are suitable for delegation to specialized agents based on complexity, independence, and other criteria for optimal workload distribution.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| complexity_threshold | string | no | Complexity level for delegation |
| independence_required | boolean | no | Require tasks to be independent (no dependencies) |
| max_estimated_hours | number | no | Maximum estimated hours for delegation |
| assignee_filter | string | no | Filter by current assignee |
| required_tags | array | no | Tasks must have these tags |
| exclude_tags | array | no | Exclude tasks with these tags |

**Example:**
```bash
mavis mcp call mcp-igniter find_delegation_candidates '{}'
```

### find_implementation

Find where a symbol (function, class, type, variable) is implemented in the codebase or dependencies.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| symbol | string | yes | Name of symbol to find (function, class, type, variable) |
| filePath | string | yes | Current file context for import resolution |
| projectRoot | string | no | Project root for better resolution |

**Example:**
```bash
mavis mcp call mcp-igniter find_implementation '{"symbol":"<symbol>","filePath":"<filePath>"}'
```

### generate_feature

**What it does:** Scaffolds a complete, new feature module according to Igniter.js conventions.
**When to use:** When starting a new, distinct area of functionality in the application (e.g., 'users', 'products', 'billing').
**How it works:** Runs 'igniter generate feature <name>'. It creates a directory with subfolders for controllers, procedures, and types.
**Result:** A new feature directory and files, ready for business logic implementation.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| name | string | yes | The name of the feature in kebab-case (e.g., 'user-management'). |
| schema | string | no | EXPERIMENTAL: Generate CRUD operations from a schema provider (e.g., 'prisma:User'). |

**Example:**
```bash
mavis mcp call mcp-igniter generate_feature '{"name":"<name>"}'
```

### generate_schema

**What it does:** Manually triggers the generation of the type-safe client schema from your API router.
**When to use:** Primarily in CI/CD environments or when you need to force a regeneration without running the dev server. The 'dev' command typically handles this automatically.
**How it works:** Runs 'igniter generate schema'. It introspects your main router file and outputs the client files.
**Result:** Updated client schema files in the specified output directory.

**Example:**
```bash
mavis mcp call mcp-igniter generate_schema '{}'
```

### get_github_issue

Gets detailed information about a specific GitHub issue.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| issueNumber | number | yes |  |
| repository | string | no | Repository in format 'owner/repo'. Defaults to 'felipebarcelospro/igniter-js' |

**Example:**
```bash
mavis mcp call mcp-igniter get_github_issue '{"issueNumber":"<issueNumber>"}'
```

### get_openapi_spec

Retrieve and parse the OpenAPI specification from the running server

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| url | string | no | Custom URL for the OpenAPI spec (defaults to local dev server) |

**Example:**
```bash
mavis mcp call mcp-igniter get_openapi_spec '{}'
```

### get_process_info

Gets detailed information about a running process by executing system commands (macOS and Linux compatible).

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| process_id | number | yes | The PID of the process. |

**Example:**
```bash
mavis mcp call mcp-igniter get_process_info '{"process_id":"<process_id>"}'
```

### get_task_statistics

Get comprehensive task statistics including workload analysis, completion rates, and performance metrics for project management and delegation planning.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| assignee | string | no | Filter statistics by specific assignee |
| feature_id | string | no | Filter statistics by specific feature |
| include_delegation_insights | boolean | no | Include insights for delegation planning |

**Example:**
```bash
mavis mcp call mcp-igniter get_task_statistics '{}'
```

### inspect_runtime_variable

Inspects the value of a variable in a running JavaScript/TypeScript process. The target process MUST be started with the --inspect flag.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| process_id | number | yes | The PID of the JavaScript/TypeScript process to inspect. |
| variable_name | string | yes | The name of the variable to inspect (must be in an accessible scope, preferably global). |
| debug_port | number | no | The port where the debugger is listening. Defaults to 9229. |
| file_path | string | no | The path of the file where the variable is declared (to help with scope resolution in the future). |

**Example:**
```bash
mavis mcp call mcp-igniter inspect_runtime_variable '{"process_id":"<process_id>","variable_name":"<variable_name>"}'
```

### list_active_delegations

List all currently active delegations (queued, running, or recently completed). Use when: getting an overview of all agent work, monitoring workload distribution, or identifying tasks that need attention. Provides comprehensive status of all active delegations.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| include_recent | boolean | no | Include recently completed delegations (last 24 hours) |
| max_results | number | no | Maximum number of results to return |

**Example:**
```bash
mavis mcp call mcp-igniter list_active_delegations '{}'
```

### list_github_issue_comments

Lists all comments on a specific GitHub issue

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| issueNumber | number | yes | The issue number to get comments for |
| repository | string | no | Repository in format 'owner/repo'. Defaults to 'felipebarcelospro/igniter-js' |
| per_page | number | no | Number of comments per page (max 100) |
| page | number | no | Page number for pagination |

**Example:**
```bash
mavis mcp call mcp-igniter list_github_issue_comments '{"issueNumber":"<issueNumber>"}'
```

### list_github_repository_content

Lists the contents of a directory within a GitHub repository. If no path is provided, it lists the root directory.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| owner | string | yes | The username or organization that owns the repository. |
| repo | string | yes | The name of the repository. |
| path | string | no | The path to the directory. Defaults to the root if not provided. |
| ref | string | no | The branch, tag, or commit SHA. Defaults to the repository's default branch. |

**Example:**
```bash
mavis mcp call mcp-igniter list_github_repository_content '{"owner":"<owner>","repo":"<repo>"}'
```

### list_processes_on_port

Lists all processes listening on or using a specific TCP/UDP port.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| port | number | yes | The TCP/UDP port to inspect (e.g., 3000, 9230). |
| protocol | string | no | Filter by protocol. If not provided, searches for both. |

**Example:**
```bash
mavis mcp call mcp-igniter list_processes_on_port '{"port":"<port>"}'
```

### list_tasks

List and filter tasks by status, priority, feature, or assignee for project management.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| status | string | no |  |
| priority | string | no |  |
| feature_id | string | no |  |
| assignee | string | no |  |
| include_subtasks | boolean | no |  |

**Example:**
```bash
mavis mcp call mcp-igniter list_tasks '{}'
```

### make_api_request

Make HTTP requests to test API endpoints

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| method | string | yes |  |
| url | string | yes |  |
| headers | object | no |  |
| body | any | no |  |
| timeout | number | no | Request timeout in milliseconds |

**Example:**
```bash
mavis mcp call mcp-igniter make_api_request '{"method":"<method>","url":"<url>"}'
```

### monitor_agent_tasks

Monitors progress and output of tasks delegated to agents with real-time logs and execution analytics. Use when: checking status of delegated work, collecting results from agent execution, debugging delegation issues, generating progress reports, or analyzing agent performance patterns. Provides comprehensive monitoring across all agent types.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| agent_type | string | no | Which agent type to monitor |
| task_filter | string | no | Filter by specific task ID or feature |
| include_logs | boolean | no | Include detailed execution logs |
| log_lines | number | no | Number of recent log lines to show |
| include_analytics | boolean | no | Include performance analytics |

**Example:**
```bash
mavis mcp call mcp-igniter monitor_agent_tasks '{}'
```

### read_as_markdown

Fetch and read a URL page as markdown

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| url | string | yes | Custom URL for documentation (when source is 'custom') |

**Example:**
```bash
mavis mcp call mcp-igniter read_as_markdown '{"url":"<url>"}'
```

### read_github_file

Reads the raw content of a file from a GitHub repository.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| owner | string | yes | The username or organization that owns the repository. |
| repo | string | yes | The name of the repository. |
| path | string | yes | The path to the file within the repository (e.g., src/main.ts). |
| ref | string | no | The branch, tag, or commit SHA. Defaults to the repository's default branch if not provided. |

**Example:**
```bash
mavis mcp call mcp-igniter read_github_file '{"owner":"<owner>","repo":"<repo>","path":"<path>"}'
```

### reflect_on_memories

Creates a periodic reflection memory summarizing insights and patterns from recent work.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| title | string | no |  |
| content | string | no | Custom reflection content. If not provided, generates automatic summary. |
| tags | array | no |  |

**Example:**
```bash
mavis mcp call mcp-igniter reflect_on_memories '{}'
```

### relate_memories

Create relationships between memories

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| from_type | string | yes |  |
| from_id | string | yes |  |
| to_type | string | yes |  |
| to_id | string | yes |  |
| relationship_type | string | yes |  |
| strength | number | no |  |
| confidence | number | no |  |

**Example:**
```bash
mavis mcp call mcp-igniter relate_memories '{"from_type":"<from_type>","from_id":"<from_id>","to_type":"<to_type>","to_id":"<to_id>","relationship_type":"<relationship_type>"}'
```

### remove_package_dependency

Removes an existing dependency from a project.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| package_name | string | yes | The name of the package to remove. |

**Example:**
```bash
mavis mcp call mcp-igniter remove_package_dependency '{"package_name":"<package_name>"}'
```

### reorder_tasks

Changes the execution order of tasks within a feature or project scope by updating task priorities and execution metadata. Use when: task priorities change, dependencies are discovered, workflow optimization is needed, or sprint planning requires resequencing. Updates task metadata to reflect new execution order.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| scope_id | string | yes | Feature ID or epic ID to reorder tasks within |
| task_order | array | yes | Array of task IDs in desired execution order |

**Example:**
```bash
mavis mcp call mcp-igniter reorder_tasks '{"scope_id":"<scope_id>","task_order":"<task_order>"}'
```

### run_tests

**What it does:** Executes the project's test suite using the configured test runner (e.g., Vitest).
**When to use:** After making changes to ensure that functionality is correct and no regressions were introduced. Essential for maintaining code quality.
**How it works:** Runs 'npm test'. The '--filter' option can be used to run tests for a specific package in a monorepo.
**Result:** A test report summarizing passed and failed tests.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| filter | string | no | Filter tests by a specific pattern or package name (e.g., '@igniter-js/core'). |
| watch | boolean | no | Run tests in watch mode to automatically re-run on file changes. |

**Example:**
```bash
mavis mcp call mcp-igniter run_tests '{}'
```

### search_github_code

Searches for code patterns across GitHub repositories for learning and integration examples.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| query | string | yes | Code search query |
| repository | string | no | Repository in format 'owner/repo'. If not specified, searches across GitHub |
| language | string | no | Programming language filter (typescript, javascript, etc.) |
| filename | string | no | Filename pattern to search in |

**Example:**
```bash
mavis mcp call mcp-igniter search_github_code '{"query":"<query>"}'
```

### search_github_issues

Search for GitHub issues across repositories

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| query | string | yes | Search query for issues |
| repository | string | no | Repository in format 'owner/repo'. Defaults to 'felipebarcelospro/igniter-js' |
| state | string | no | Issue state filter |
| labels | array | no | Labels to filter by |
| sort | string | no | Sort order |
| order | string | no | Sort direction |
| per_page | number | no | Number of results per page (max 100) |

**Example:**
```bash
mavis mcp call mcp-igniter search_github_issues '{"query":"<query>"}'
```

### search_memories

Search through stored memories using text, tags, or filters

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| text | string | no |  |
| tags | array | no |  |
| type | string | no |  |
| confidence_min | number | no |  |
| confidence_max | number | no |  |
| include_sensitive | boolean | no |  |

**Example:**
```bash
mavis mcp call mcp-igniter search_memories '{}'
```

### setup_agent_environment

Provides comprehensive setup guidance for agent task delegation capabilities with step-by-step instructions and automated installation options. Use when: initial environment setup, fixing configuration issues, updating delegation tools, or onboarding new developers. Includes Node.js, Docker, API keys, and agent CLI configuration with platform-specific instructions.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| platform | string | no | Target platform for setup instructions |
| format | string | no | Output format for instructions |
| include_docker | boolean | no | Include Docker setup instructions |
| include_api_setup | boolean | no | Include API key setup instructions |

**Example:**
```bash
mavis mcp call mcp-igniter setup_agent_environment '{}'
```

### start_dev_server

**What it does:** Starts the Igniter.js development server, enabling live reloading, client generation, and interactive debugging.
**When to use:** At the beginning of a development session to run the project locally. This is the primary way to test changes in real-time.
**How it works:** It programmatically runs 'npm run dev', which often starts both the web framework (like Next.js) and the Igniter.js client generator.
**Result:** A running development server, with output logs streamed to the response.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| port | number | no | Port to run the server on. Defaults to the project's standard port (e.g., 3000). |
| watch | boolean | no | Enable file watching for automatic restarts and client regeneration. Defaults to true. |

**Example:**
```bash
mavis mcp call mcp-igniter start_dev_server '{}'
```

### store_memory

ALWAYS use this tool to store something that you want to remember (Except Tasks, for tasks you need to use create_task tool). You can check your memories in the .github/lia/memories/

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| type | string | no |  |
| title | string | yes |  |
| content | string | yes |  |
| category | string | no |  |
| confidence | number | no |  |
| tags | array | no |  |
| related_memories | array | no |  |

**Example:**
```bash
mavis mcp call mcp-igniter store_memory '{"title":"<title>","content":"<content>"}'
```

### trace_dependency_chain

Map complete dependency chain for a symbol, showing the path from usage to original implementation.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| symbol | string | yes | Symbol to trace |
| startFile | string | yes | Starting file |
| maxDepth | number | no | Maximum trace depth to prevent infinite loops |

**Example:**
```bash
mavis mcp call mcp-igniter trace_dependency_chain '{"symbol":"<symbol>","startFile":"<startFile>"}'
```

### update_github_issue

Updates an existing GitHub issue (title, body, labels, assignees, state, etc.)

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| issueNumber | number | yes | The issue number to update |
| repository | string | no | Repository in format 'owner/repo'. Defaults to 'felipebarcelospro/igniter-js' |
| title | string | no | New title for the issue |
| body | string | no | New body/description for the issue |
| labels | array | no | Labels to set on the issue |
| assignees | array | no | Users to assign to the issue |
| state | string | no | New state for the issue |
| milestone | number | no | Milestone number to associate with the issue |

**Example:**
```bash
mavis mcp call mcp-igniter update_github_issue '{"issueNumber":"<issueNumber>"}'
```

### update_github_issue_comment

Updates an existing comment on a GitHub issue

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| commentId | number | yes | The comment ID to update |
| body | string | yes | The new comment body |
| repository | string | no | Repository in format 'owner/repo'. Defaults to 'felipebarcelospro/igniter-js' |

**Example:**
```bash
mavis mcp call mcp-igniter update_github_issue_comment '{"commentId":"<commentId>","body":"<body>"}'
```

### update_task_status

Update the status of a specific task and track completion time.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| task_id | string | yes |  |
| new_status | string | yes |  |
| notes | string | no |  |

**Example:**
```bash
mavis mcp call mcp-igniter update_task_status '{"task_id":"<task_id>","new_status":"<new_status>"}'
```

### visualize_memory_graph

Generate a Mermaid diagram of memory relationships

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| center_type | string | yes |  |
| center_id | string | yes |  |
| depth | number | no |  |

**Example:**
```bash
mavis mcp call mcp-igniter visualize_memory_graph '{"center_type":"<center_type>","center_id":"<center_id>"}'
```

