#!/usr/bin/env node
'use strict';

/*
 * Validate quest YAML with the same structural rules used by the quest plugin.
 * Human output is default; --json is intended for CI and other tooling.
 */

const fs = require('node:fs');
const path = require('node:path');
const { parse: parseYaml } = require('yaml');

const repoRoot = path.resolve(__dirname, '..');
const args = new Set(process.argv.slice(2));
const jsonOutput = args.has('--json');
const dirArg = process.argv.find((value) => value.startsWith('--dir='));
const questDir = dirArg
  ? path.resolve(dirArg.slice('--dir='.length))
  : path.join(repoRoot, 'payload', 'agents');

const MODEL_REF = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.:-]+(?:\/[A-Za-z0-9_.:-]+)*$/;

function error(errors, message) {
  errors.push(message);
}

function validateQuest(doc, fileName) {
  const errors = [];
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) {
    error(errors, 'expected a YAML object');
    return errors;
  }
  if (doc.kind !== 'quest') error(errors, 'kind must be "quest"');
  if (typeof doc.name !== 'string' || !doc.name.trim()) error(errors, 'name is required');
  if (doc.description !== undefined && typeof doc.description !== 'string') {
    error(errors, 'description must be a string');
  }
  if (doc.context !== undefined && typeof doc.context !== 'string') {
    error(errors, 'context must be a string');
  }
  if (doc.timeout !== undefined &&
      (typeof doc.timeout !== 'number' || !Number.isFinite(doc.timeout) || doc.timeout <= 0)) {
    error(errors, 'timeout must be a positive number (seconds)');
  }
  if (!Array.isArray(doc.stages) || doc.stages.length === 0) {
    error(errors, 'stages must be a non-empty array');
    return errors;
  }

  const stageIds = new Set();
  const transitions = [];
  doc.stages.forEach((stage, index) => {
    const prefix = `stages[${index}]`;
    if (!stage || typeof stage !== 'object' || Array.isArray(stage)) {
      error(errors, `${prefix} must be an object`);
      return;
    }
    if (typeof stage.id !== 'string' || !stage.id.trim()) {
      error(errors, `${prefix}.id is required`);
    } else if (stageIds.has(stage.id.trim())) {
      error(errors, `duplicate stage id "${stage.id.trim()}"`);
    } else {
      stageIds.add(stage.id.trim());
    }

    for (const field of ['description', 'instruction', 'context']) {
      if (stage[field] !== undefined && typeof stage[field] !== 'string') {
        error(errors, `${prefix}.${field} must be a string`);
      }
    }
    if (stage.checklist !== undefined) {
      if (!Array.isArray(stage.checklist)) {
        error(errors, `${prefix}.checklist must be an array`);
      } else {
        stage.checklist.forEach((item, itemIndex) => {
          if (typeof item !== 'string') error(errors, `${prefix}.checklist[${itemIndex}] must be a string`);
        });
      }
    }
    if (stage.agent !== undefined &&
        (typeof stage.agent !== 'string' || !stage.agent.trim())) {
      error(errors, `${prefix}.agent must be a non-empty string`);
    }
    if (stage.model !== undefined &&
        (typeof stage.model !== 'string' || !MODEL_REF.test(stage.model.trim()))) {
      error(errors, `${prefix}.model must match "providerID/modelID"`);
    }

    if (stage.next !== undefined) {
      if (typeof stage.next === 'string') {
        if (!stage.next.trim()) error(errors, `${prefix}.next cannot be empty`);
        transitions.push([stage.id, [stage.next.trim()]]);
      } else if (stage.next && typeof stage.next === 'object' && !Array.isArray(stage.next)) {
        const entries = Object.entries(stage.next);
        if (entries.length === 0) error(errors, `${prefix}.next cannot be empty (no labels)`);
        const targets = [];
        for (const [label, target] of entries) {
          if (typeof target !== 'string' || !target.trim()) {
            error(errors, `${prefix}.next["${label}"] must be a non-empty string`);
          } else {
            targets.push(target.trim());
          }
        }
        transitions.push([stage.id, targets]);
      } else {
        error(errors, `${prefix}.next must be a string or an object with labeled exits`);
      }
    }
  });

  for (const [stageId, targets] of transitions) {
    for (const target of targets) {
      if (!stageIds.has(target)) {
        error(errors, `stage "${stageId}" next target "${target}" does not exist`);
      }
    }
  }
  return errors;
}

function validateFile(fileName) {
  const filePath = path.join(questDir, fileName);
  try {
    const document = parseYaml(fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, ''));
    const errors = validateQuest(document, fileName);
    return { file: fileName, ok: errors.length === 0, ...(errors.length ? { errors } : {}) };
  } catch (cause) {
    return { file: fileName, ok: false, errors: [`YAML parse failed: ${cause.message}`] };
  }
}

let files = [];
let directoryError = null;
try {
  files = fs.readdirSync(questDir)
    .filter((name) => /\.(yaml|yml)$/i.test(name))
    .sort((a, b) => a.localeCompare(b));
} catch (cause) {
  directoryError = `cannot read quest directory: ${cause.message}`;
}

const results = directoryError
  ? []
  : files.map(validateFile);
if (directoryError) results.push({ file: '.', ok: false, errors: [directoryError] });
if (!directoryError && results.length === 0) {
  results.push({ file: '.', ok: false, errors: ['no .yaml or .yml quest files found'] });
}

const invalid = results.filter((result) => !result.ok);
const output = {
  ok: invalid.length === 0,
  directory: questDir,
  files: results,
  summary: {
    total: results.length,
    valid: results.length - invalid.length,
    invalid: invalid.length,
  },
};

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
} else {
  process.stdout.write(`Quest validation: ${output.ok ? 'OK' : 'FAIL'}\nDirectory: ${questDir}\n`);
  for (const result of results) {
    process.stdout.write(`[${result.ok ? 'PASS' : 'FAIL'}] ${result.file}`);
    if (result.errors) process.stdout.write(` - ${result.errors.join('; ')}`);
    process.stdout.write('\n');
  }
}

process.exitCode = output.ok ? 0 : 1;
