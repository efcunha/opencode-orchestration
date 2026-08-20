'use strict';
// Node 22+ emite DEP0190 quando child_process e spawnado com shell:true em
// .cmd/.ps1 (que e exatamente o caso do opencode em Windows). E um aviso
// informativo, nao um problema - silenciar para nao poluir stdout durante
// a renderizacao do wizard.
process.removeAllListeners('warning');

/*
 * discover.js — descobre providers/models que o opencode ja tem configurados.
 *
 * Fontes de informacao (executadas pelo `opencode` em diretorio vazio, para
 * garantir que a config resolvida vem da configuracao global e nao de algum
 * opencode.json de projeto que estivesse no cwd):
 *
 *   opencode models --verbose
 *     Lista modelos com metadados completos:
 *       providerID, id, name, api.npm, api.url, options, headers,
 *       limit.context, limit.output, cost, capabilities
 *
 *   opencode providers list
 *     Lista providers conhecidos pelo opencode:
 *       Credentials (autenticados via `opencode auth`) - nao tem env var
 *       Environment (autenticados via env var) - tem env var
 *
 * Saida:
 *   {
 *     models:        [{ providerID, id, name, npm, url, limit, options, headers, cost, capabilities }],
 *     envByProvider: { 'deepseek': 'DEEPSEEK_API_KEY', 'openrouter': 'OPENROUTER_API_KEY', ... }
 *   }
 */

const { spawnSync } = require('node:child_process');
const path = require('node:path');
const os = require('node:os');
const fs = require('node:fs');

function run(cmd, args, cwd) {
    // stdio: 'ignore' para stdin e crucial - senao o shell filho em Windows
    // herda o stdin do pai, o que pode drenar a pipe que o wizard usa
    // para prompts interativos.
    const opts = { encoding: 'utf8', cwd, stdio: ['ignore', 'pipe', 'pipe'] };
    let r;
    if (process.platform === 'win32') {
        r = spawnSync(cmd, args, { ...opts, shell: true });
    } else {
        r = spawnSync(cmd, args, opts);
    }
    if (r.status !== 0) {
        const e = (r.stderr || '').trim();
        return { stdout: '', stderr: e, code: r.status };
    }
    return { stdout: r.stdout || '', stderr: '', code: 0 };
}

function parseVerbose(stdout) {
    const out = [];
    const blocks = stdout.split(/^(?=[A-Za-z0-9_.-]+\/[A-Za-z0-9_.:-]+\s*$)/m);
    for (const blk of blocks) {
        const trimmed = blk.trim();
        if (!trimmed) continue;
        const braceAt = trimmed.indexOf('{');
        if (braceAt < 0) continue;
        const json = trimmed.slice(braceAt);
        try {
            const o = JSON.parse(json);
            if (o && o.providerID && o.id) out.push(o);
        } catch (_) { /* bloco mal-formado, pula */ }
    }
    return out;
}

function parseProvidersList(stdout) {
    const envByProvider = {};
    let section = '';
    for (const rawLine of stdout.split(/\r?\n/)) {
        const line = rawLine.replace(/\u001b\[[0-9;]*m/g, '').trim();
        if (!line) continue;
        if (/credentials/i.test(line) && /~\.local/.test(line)) { section = 'creds'; continue; }
        if (/environment/i.test(line) && !/variables?/i.test(line)) { section = 'env'; continue; }
        if (/^───|^——|^—/.test(line)) continue;
        if (section !== 'env') continue;
        const m = line.match(/^(?:•\s*)?(.+?)\s+([A-Z][A-Z0-9_]+)\s*$/);
        if (!m) continue;
        const [, displayName, envVar] = m;
        const lower = displayName.toLowerCase();
        const providerId = lower.includes('deepseek')   ? 'deepseek'
                          : lower.includes('openrouter') ? 'openrouter'
                          : lower.includes('cloudflare') ? 'cloudflare'
                          : lower.includes('minimax')    ? 'minimax-coding-plan'
                          : lower.includes('zen')        ? 'opencode-zen'
                          : lower.includes('nvidia')      ? 'nvidia'
                          : lower.includes('anthropic')   ? 'anthropic'
                          : lower.includes('openai')      ? 'openai'
                          : lower.replace(/\s*\(.*?\)/g, '').replace(/[^a-z0-9-]+/g, '-');
        if (envByProvider[providerId] == null) envByProvider[providerId] = envVar;
    }
    return envByProvider;
}

function aggregate(model, envVar) {
    const a = {
        providerID: model.providerID,
        id:         model.id,
        fullId:     `${model.providerID}/${model.id}`,
        name:       model.name || model.id,
        npm:        model.api?.npm || null,
        url:        model.api?.url || null,
        limit:      model.limit || {},
        options:    model.options || {},
        headers:    model.headers || {},
        cost:       model.cost || {},
        envVar:     envVar || null,
    };
    return a;
}

function discover(cwd) {
    cwd = cwd || os.tmpdir();
    if (!fs.existsSync(cwd)) fs.mkdirSync(cwd, { recursive: true });

    const m = run('opencode', ['models', '--verbose'], cwd);
    if (m.code !== 0) {
        return { ok: false, error: `opencode models --verbose falhou (exit ${m.code}): ${m.stderr}` };
    }
    const rawModels = parseVerbose(m.stdout);

    const p = run('opencode', ['providers', 'list'], cwd);
    let envByProvider = {};
    if (p.code === 0) {
        envByProvider = parseProvidersList(p.stdout);
    }

    const models = rawModels.map((mdl) => aggregate(mdl, envByProvider[mdl.providerID]));
    return { ok: true, models, envByProvider, raw: { models: rawModels, providers: p.stdout } };
}

if (require.main === module) {
    const r = discover();
    if (!r.ok) { console.error(r.error); process.exit(1); }
    console.log(JSON.stringify({
        models: r.models,
        envByProvider: r.envByProvider,
    }, null, 2));
}

module.exports = { discover, parseVerbose, parseProvidersList, aggregate };
