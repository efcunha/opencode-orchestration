#!/usr/bin/env node
/*
 * wizard.js — instalacao interativa da config de LLM.
 *
 * Roda quando o usuario nao tem config/llm-providers.json e o shell e TTY.
 * Lista os models que o opencode ja tem configurados (via discover.js),
 * pergunta ao usuario qual vai para cada slot de agente (plan, build,
 * review, etc.), e salva o resultado.
 *
 * Nao escreve em config.llm-providers.json do nada: o usuario precisa
 * aceitar cada prompt. Aceitar tudo com default = mesma coisa que usar
 * os defaults hardcoded.
 *
 * Uso:
 *   node scripts/wizard.js
 *   node scripts/wizard.js --output path/to/file.json
 */

'use strict';
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const { discover } = require('./discover');

const slots = [
    { id: 'plan',    description: 'planejamento, arquitetura e reproducao de defeito' },
    { id: 'build',   description: 'implementacao de codigo' },
    { id: 'review',  description: 'revisao independente' },
    { id: 'bugfix',  description: 'diagnostico e correcao de bugs' },
    { id: 'general', description: 'subagente de proposito geral' },
    { id: 'explore', description: 'subagente de exploracao de codigo' },
];

/**
 * Lê TODO o stdin uma vez e devolve linhas sob demanda. Necessario porque
 * em Windows, stdin redirecionado (cmd < file, Get-Content | ...) sinaliza
 * EOF depois de uma unica leitura - readline.question e data events nao
 * funcionam normalmente no segundo prompt.
 */
function preLoadStdin() {
    return new Promise((resolve) => {
        let buf = '';
        const onData = (chunk) => { buf += chunk.toString('utf8'); };
        const onEnd = () => {
            const lines = buf.split(/\r?\n/).filter((l) => l.length > 0);
            resolve(lines);
        };
        process.stdin.on('data', onData);
        process.stdin.on('end', onEnd);
        process.stdin.resume();
    });
}

let _stdinLines = [];
let _stdinCursor = 0;
let _isTTY = false;
let _rl = null;

function readLine(prompt) {
    if (_isTTY && _rl) {
        // Modo interativo: usa readline para perguntar ao usuario
        return new Promise((resolve) => {
            _rl.question(prompt, (answer) => {
                resolve(answer || '');
            });
        });
    }
    // Modo piped/redirected: consome linhas pre-carregadas
    process.stdout.write(prompt);
    if (_stdinCursor >= _stdinLines.length) {
        process.stderr.write('[wizard] stdin exhausted (EOF antes de ler todas as respostas). Saindo.\n');
        process.exit(1);
    }
    const line = _stdinLines[_stdinCursor++];
    return Promise.resolve(line);
}

function ask(prompt, fallback) {
    return readLine(prompt).then((answer) => {
        const a = (answer || '').trim();
        return a.length ? a : fallback;
    });
}

function pickModel(models, slot, defaultIdx) {
    return new Promise((resolve) => {
        console.log('');
        console.log(`  Slot: ${slot.id}`);
        console.log(`  Funcao: ${slot.description}`);
        promptModelList(models);
        const defaultStr = defaultIdx >= 0 ? ` [default: ${defaultIdx + 1}]` : '';
        readLine(`  Escolha [1-${models.length} ou 0]${defaultStr}: `).then((answer) => {
            resolve(parseModelPick(answer, models, defaultIdx));
        });
    });
}

function pickModelIndex(models, label, defaultIdx) {
    return new Promise((resolve) => {
        promptModelList(models);
        const defaultStr = defaultIdx >= 0 ? ` [default: ${defaultIdx + 1}]` : '';
        readLine(`  Escolha para ${label} [1-${models.length} ou 0]${defaultStr}: `).then((answer) => {
            resolve(parseModelPick(answer, models, defaultIdx));
        });
    });
}

function promptModelList(models) {
    console.log('  Models disponiveis:');
    const maxName = Math.max(...models.map((m) => (m.name || m.id).length));
    const maxCost = Math.max(...models.map((m) => (m.fullId || '').length));
    models.forEach((m, i) => {
        const num = (i + 1).toString().padStart(2, ' ');
        const fullId = (m.fullId || '').padEnd(maxCost, ' ');
        const name = (m.name || m.id).padEnd(maxName, ' ');
        const cost = (m.envVar ? `[key: ${m.envVar}]` : '[sem key]');
        console.log(`    ${num}. ${fullId}  ${name}  ${cost}`);
    });
    console.log('     0. (pular)');
}

function parseModelPick(answer, models, defaultIdx) {
    const a = (answer || '').trim();
    if (a.length === 0 && defaultIdx >= 0) return defaultIdx;
    if (a === '0') return -1;
    const n = parseInt(a, 10);
    if (n >= 1 && n <= models.length) return n - 1;
    console.log(`  (valor invalido '${a}'; usando pular/default)`);
    return -1;
}

function buildProviderBlocks(models, envByProvider) {
    const providers = {};
    for (const m of models) {
        if (providers[m.providerID]) continue;
        const envVar = m.envVar || envByProvider[m.providerID] || null;
        providers[m.providerID] = {
            npm: m.npm,
            options: {
                baseURL: m.url,
                ...(envVar ? { apiKey: `{env:${envVar}}` } : {}),
            },
            whitelist: [],
            models: {},
        };
    }
    for (const m of models) {
        const p = providers[m.providerID];
        if (!p.whitelist.includes(m.id)) p.whitelist.push(m.id);
        p.models[m.id] = {
            name: m.name || m.id,
            limit: m.limit || {},
        };
    }
    return providers;
}

async function main() {
    const argv = process.argv.slice(2);
    let outputPath = path.join(process.cwd(), 'config', 'llm-providers.json');
    let skipIfMissing = true;
    for (let i = 0; i < argv.length; i++) {
        if (argv[i] === '--output') outputPath = argv[++i];
        else if (argv[i] === '--force') skipIfMissing = false;
    }

    if (process.stdin.isTTY) {
        _isTTY = true;
        _stdinLines = [];
    } else {
        _isTTY = false;
        _stdinLines = await preLoadStdin();
    }

    if (fs.existsSync(outputPath) && skipIfMissing) {
        console.error(`[wizard] ja existe $${outputPath}. Use --force para sobrescrever ou edite manualmente.`);
        process.exit(0);
    }

    console.log('[wizard] descobrindo models que o opencode tem configurados...');
    const cwd = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'opencode-orch-'));
    const disc = discover(cwd);
    fs.rmSync(cwd, { recursive: true, force: true });
    if (!disc.ok) {
        console.error(`[wizard] descoberta falhou: ${disc.error}`);
        process.exit(1);
    }
    if (disc.models.length === 0) {
        console.error('[wizard] opencode nao retornou nenhum model. Provavelmente o opencode nao esta instalado ou nao tem credenciais.');
        process.exit(1);
    }

    const chatModels = disc.models.filter((m) => !(m.id || '').toLowerCase().includes('embed'));
    if (chatModels.length === 0) {
        console.error('[wizard] todos os models descobertos parecem ser de embedding. Configure pelo menos um model de chat no opencode.');
        process.exit(1);
    }

    console.log(`[wizard] ${chatModels.length} model(s) de chat descoberto(s):`);
    chatModels.forEach((m) => {
        console.log(`  ${m.fullId} - ${m.name}${m.envVar ? ` (env: ${m.envVar})` : ''}`);
    });

    _rl = readline.createInterface({
        input:  process.stdin,
        output: process.stdout,
        terminal: process.stdin.isTTY === true,
    });
    try {
        const picks = {};
        const defaultIdx = 0;
        for (const slot of slots) {
            const idx = await pickModel(chatModels, slot, defaultIdx);
            if (idx >= 0) {
                const m = chatModels[idx];
                picks[slot.id] = {
                    model: m.fullId,
                    temperature: 0.1,
                    description: `${slot.description} via ${m.name || m.id}.`,
                };
            }
        }
        console.log('');
        console.log('  Model default (root). Escolha [1-3], Enter para o 1o escolhido:');
        const modelDefaultIdx = await pickModelIndex(chatModels, 'model default', picks.plan ? chatModels.findIndex((m) => m.fullId === picks.plan.model) : 0);
        console.log('');
        console.log('  Small model (tarefas leves). Escolha [1-3], Enter para o 1o escolhido:');
        const smallIdx = await pickModelIndex(chatModels, 'small_model', picks.build ? chatModels.findIndex((m) => m.fullId === picks.build.model) : 0);
        const rootModel = modelDefaultIdx >= 0 ? chatModels[modelDefaultIdx].fullId : (picks.plan?.model || chatModels[0].fullId);
        const smallModel = smallIdx >= 0 ? chatModels[smallIdx].fullId : (picks.build?.model || chatModels[0].fullId);

        console.log('\nResumo:');
        console.log(`  model       = ${rootModel}`);
        console.log(`  small_model = ${smallModel}`);
        for (const [k, v] of Object.entries(picks)) {
            console.log(`  agent.${k}.model = ${v.model}`);
        }

        const confirmed = await ask('\n  Salvar em ' + outputPath + '? [Y/n]: ', 'Y');
        if (!/^y(es)?$/i.test(confirmed || 'Y')) {
            console.log('[wizard] cancelado.');
            return;
        }

        const providers = buildProviderBlocks(chatModels, disc.envByProvider);
        const config = {
            enabled_providers: [...new Set(chatModels.map((m) => m.providerID))],
            model: rootModel,
            small_model: smallModel,
            agents: picks,
            providers,
        };
        const dir = path.dirname(outputPath);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(outputPath, JSON.stringify(config, null, 2) + '\n', 'utf8');
        console.log(`[wizard] salvo em ${outputPath}`);
    } finally {
        if (_rl) _rl.close();
        _rl = null;
    }
}

main().catch((err) => {
    console.error('[wizard] erro:', err.message);
    process.exit(1);
});
