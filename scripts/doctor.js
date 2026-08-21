#!/usr/bin/env node
'use strict';

/*
 * Structured, low-side-effect diagnostics for an installed orchestration payload.
 * Human output remains available by default; --json is intended for CI and tools.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const repoRoot = path.resolve(__dirname, '..');
const args = new Set(process.argv.slice(2));
const jsonOutput = args.has('--json');
const skipOpenCode = args.has('--skip-opencode');
const targetArg = process.argv.find((value) => value.startsWith('--target-root='));
const targetRoot = targetArg
  ? path.resolve(targetArg.slice('--target-root='.length))
  : path.join(os.homedir(), '.config', 'opencode');

const checks = [];

function check(id, ok, detail = '', severity = 'blocking') {
  checks.push({
    id,
    status: ok ? 'pass' : severity === 'warning' ? 'warn' : 'fail',
    severity,
    ...(detail ? { detail } : {}),
  });
}

function readText(filePath) {
  return fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, '');
}

function parseJsonc(text) {
  const withoutBlocks = text.replace(/\/\*[\s\S]*?\*\//g, '');
  const withoutLineComments = withoutBlocks
    .split(/\r?\n/)
    .filter((line) => !line.trimStart().startsWith('//'))
    .join('\n');
  const withoutTrailingCommas = withoutLineComments.replace(/,\s*([}\]])/g, '$1');
  return JSON.parse(withoutTrailingCommas);
}

function commandName(name) {
  return process.platform === 'win32' ? `${name}.cmd` : name;
}

function discoverModels() {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'opencode-orch-doctor-'));
  try {
    const command = spawnSync(commandName('opencode'), ['models'], {
      cwd,
      encoding: 'utf8',
      windowsHide: true,
    });
    const output = `${command.stdout || ''}\n${command.stderr || ''}`;
    const models = new Set();
    for (const line of output.split(/\r?\n/)) {
      const value = line.trim();
      if (/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.:-]+$/.test(value)) models.add(value);
    }
    return { command, models };
  } finally {
    fs.rmSync(cwd, { recursive: true, force: true });
  }
}

const configPath = path.join(targetRoot, 'opencode.jsonc');
const pluginPath = path.join(targetRoot, 'plugins', 'opencode-quests.ts');
const questDir = path.join(targetRoot, 'agents');

check('target.exists', fs.existsSync(targetRoot), targetRoot);
check('config.exists', fs.existsSync(configPath), configPath);
check('plugin.quests.exists', fs.existsSync(pluginPath), pluginPath);

let config = null;
if (fs.existsSync(configPath)) {
  try {
    const raw = readText(configPath);
    config = parseJsonc(raw);
    check('config.parse', true, 'opencode.jsonc is valid JSONC');
    check('config.placeholders', !/\{\{\w+\}\}/.test(raw), 'No unresolved template placeholders');
  } catch (error) {
    check('config.parse', false, error.message);
  }
}

const questFiles = fs.existsSync(questDir)
  ? fs.readdirSync(questDir).filter((name) => /\.(yaml|yml)$/i.test(name))
  : [];
check('quests.exists', questFiles.length > 0, `${questFiles.length} quest file(s)`);

const packageJson = JSON.parse(readText(path.join(repoRoot, 'package.json')));
const declaredDependencies = {
  ...(packageJson.dependencies || {}),
  ...(packageJson.optionalDependencies || {}),
};
check(
  'runtime.yaml.declared',
  Object.prototype.hasOwnProperty.call(declaredDependencies, 'yaml'),
  'payload/plugins/opencode-quests.ts imports yaml',
);
check(
  'package.lock.exists',
  fs.existsSync(path.join(repoRoot, 'package-lock.json')),
  'Commit package-lock.json for reproducible installs',
  'warning',
);

if (config && config.mcp) {
  for (const [name, definition] of Object.entries(config.mcp)) {
    const command = definition && Array.isArray(definition.command) ? definition.command : [];
    if (command[0] !== 'node' || !command[1]) {
      check(`mcp.${name}`, true, 'External or npx MCP; binary check skipped', 'warning');
      continue;
    }
    check(`mcp.${name}.binary`, fs.existsSync(command[1]), command[1]);
  }
}

if (config) {
  const modelRefs = [];
  for (const key of ['model', 'small_model']) {
    if (typeof config[key] === 'string') modelRefs.push([key, config[key]]);
  }
  for (const [name, agent] of Object.entries(config.agent || {})) {
    if (agent && typeof agent.model === 'string') modelRefs.push([`agent.${name}.model`, agent.model]);
  }

  if (skipOpenCode) {
    check('models.discovery', true, 'Skipped by --skip-opencode', 'warning');
  } else {
    const discovered = discoverModels();
    if (discovered.command.error || discovered.command.status !== 0) {
      check('models.discovery', true, 'opencode unavailable; model resolution not checked', 'warning');
    } else {
      check('models.discovery', discovered.models.size > 0, `${discovered.models.size} model(s) discovered`);
      for (const [name, ref] of modelRefs) {
        check(`model.${name}`, discovered.models.has(ref), ref);
      }
    }
  }
}

const failed = checks.filter((item) => item.status === 'fail');
const result = {
  ok: failed.length === 0,
  targetRoot,
  checks,
  summary: {
    pass: checks.filter((item) => item.status === 'pass').length,
    warnings: checks.filter((item) => item.status === 'warn').length,
    failures: failed.length,
  },
};

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} else {
  process.stdout.write(`Doctor: ${result.ok ? 'OK' : 'FAIL'}\nTarget: ${targetRoot}\n`);
  for (const item of checks) {
    const marker = item.status === 'pass' ? 'PASS' : item.status === 'warn' ? 'WARN' : 'FAIL';
    process.stdout.write(`[${marker}] ${item.id}${item.detail ? ` - ${item.detail}` : ''}\n`);
  }
}

process.exitCode = result.ok ? 0 : 1;
