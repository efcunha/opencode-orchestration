#!/usr/bin/env node
/*
 * install.js — entry point for `npm install`/`npm install -g` of this repo.
 *
 * O npm ja instalou as dependencias de MCPs (em dependencies/optionalDependencies
 * do package.json). Este script fecha o ciclo:
 *   1. Detecta caminhos locais: `npm root -g`, $USERPROFILE, $HOME.
 *   2. Repassa para o instalador PowerShell como variaveis de ambiente.
 *   3. O PowerShell renderiza os templates `payload/opencode.jsonc` e
 *      `payload-symlinks.template.json`, copia o payload para TargetRoot e
 *      roda Test-Orchestration.ps1 no fim.
 *
 * Em modo `--postinstall` (chamado pelo npm apos instalar deps), NAO escreve
 * sem confirmacao: aborta se alguma condicao for infactivel. Isso deixa
 * `npm install -g .` numa maquina sem opencode Powershell utilizavel sem efeito.
 *
 * Em modo `--force` ou sem flag, chama `Install-Orchestration.ps1 -Force`
 * (que ainda respeita -WhatIf do PowerShell se ORCHESTRATION_DRY_RUN=1).
 */

// Silence Node 22+ deprecation warnings raised by spawnSync(.cmd, shell:true)
// on Windows. The behavior we want is intentional (npm.cmd/.ps1 are .cmd/.ps1
// files, not native exes — Node requires the shell wrapper on Win). The
// warning is informational; we know.
process.removeAllListeners('warning');

'use strict';

const { spawn, spawnSync } = require('node:child_process');
const path = require('node:path');
const os = require('node:os');
const fs = require('node:fs');
const tty = require('node:tty');

const args = new Set(process.argv.slice(2));
const isPostinstall = args.has('--postinstall');
const isUninstall   = args.has('--uninstall');
const isForce       = args.has('--force') || isPostinstall;

const repoRoot  = path.resolve(__dirname, '..');
const psScript  = path.join(repoRoot, 'scripts', 'Install-Orchestration.ps1');

function log(msg) { process.stdout.write(msg + os.EOL); }
function warn(msg) { process.stderr.write('[opencode-orchestration] ' + msg + os.EOL); }

function detectNpmRootGlobal() {
    const cmd = process.platform === 'win32' ? 'npm.cmd' : 'npm';
    const r = spawnSync(cmd, ['root', '-g'], { encoding: 'utf8' });
    if (r.status !== 0 || !r.stdout) {
        const sh = spawnSync('npm', ['root', '-g'], { encoding: 'utf8', shell: true });
        if (sh.status === 0 && sh.stdout) return sh.stdout.trim();
        return null;
    }
    return r.stdout.trim();
}

function detectUserHome() {
    return process.env.USERPROFILE || process.env.HOME || os.homedir();
}

function envSummary(env) {
    const keys = Object.keys(env).filter((k) => k.startsWith('ORCH_'));
    const out = {};
    for (const k of keys.sort()) out[k] = env[k];
    return out;
}

function findPwsh() {
    const candidates = process.platform === 'win32'
        ? ['pwsh.exe', 'powershell.exe']
        : ['pwsh', 'powershell'];
    for (const cmd of candidates) {
        const r = spawnSync(cmd, ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'],
                            { encoding: 'utf8' });
        if (r.status === 0 && r.stdout) {
            return cmd.trim();
        }
        const sh = spawnSync(cmd, ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'],
                             { encoding: 'utf8', shell: true });
        if (sh.status === 0 && sh.stdout) {
            return cmd.trim();
        }
    }
    return null;
}

function maybeRunWizard() {
    const configPath = path.join(repoRoot, 'config', 'llm-providers.json');
    const force = args.has('--wizard');
    if (fs.existsSync(configPath) && !force) return false;
    if (!process.stdin.isTTY) {
        if (force) {
            warn('wizard precisa de TTY (stdin nao e terminal interativo).');
        }
        return false;
    }
    if (!force && !args.has('--postinstall')) return false;
    const wizardScript = path.join(repoRoot, 'scripts', 'wizard.js');
    if (!fs.existsSync(wizardScript)) return false;
    const args2 = force ? [wizardScript, '--output', configPath, '--force'] : [wizardScript, '--output', configPath];
    log('');
    if (force) {
        log('[opencode-orchestration] rodando wizard manualmente (--wizard).');
    } else {
        log('[opencode-orchestration] nenhum config/llm-providers.json encontrado. Rodando wizard interativo...');
        log('  Para pular (instalacao silenciosa), copie scripts/llm-providers.example.json para config/llm-providers.json antes.');
    }
    log('');
    const r = spawnSync(process.execPath, args2, { stdio: 'inherit' });
    if (r.status !== 0) {
        warn(`wizard saiu com codigo ${r.status}. Continuando com defaults.`);
        return false;
    }
    return fs.existsSync(configPath);
}

function runPowerShell(cmd, argsList, env) {
    return new Promise((resolve, reject) => {
        const child = spawn(cmd, argsList, {
            stdio: 'inherit',
            env: env || process.env,
            windowsHide: true,
        });
        child.on('error', reject);
        child.on('close', (code) => {
            if (code === 0) resolve();
            else reject(new Error(`${cmd} exited with code ${code}`));
        });
    });
}

async function main() {
    maybeRunWizard();

    const nodeModules = detectNpmRootGlobal();
    const userHome    = detectUserHome();
    const userAgents  = path.join(userHome, '.agents');
    const pwsh        = findPwsh();

    if (!pwsh) {
        warn('PowerShell nao encontrado no PATH. A instalacao automatica requer pwsh (PowerShell 7+).');
        warn('Instale PowerShell 7: https://learn.microsoft.com/powershell/install/');
        if (!isForce) {
            warn('Abortando sem escrever nada. Para forcar mesmo sem PowerShell: npm run install:force');
            process.exit(1);
        }
    }

    if (!nodeModules) {
        warn('Nao consegui detectar o diretorio global de node_modules (npm root -g falhou).');
        if (!isForce) {
            warn('Abortando. Confira se o npm esta instalado e visivel no PATH.');
            process.exit(2);
        }
    }

    const env = { ...process.env };
    env.ORCH_NPM_GLOBAL_NODE_MODULES = nodeModules || '';
    env.ORCH_USER_HOME               = userHome;
    env.ORCH_USER_AGENTS             = userAgents;
    env.ORCH_POSTINSTALL             = isPostinstall ? '1' : '0';
    env.ORCH_FORCE                   = isForce ? '1' : '0';

    if (isUninstall) {
        log('[opencode-orchestration] uninstall: a cargo do usuario (mcp e payload ja removidos pelo npm)');
        return;
    }

    const psArgs = [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', psScript,
    ];
    if (isForce) psArgs.push('-Force');

    log('');
    log('[opencode-orchestration] detectado:');
    log('  node_modules global : ' + (nodeModules || '(nao detectado)'));
    log('  user home           : ' + userHome);
    log('  user agents dir     : ' + userAgents);
    log('  powershell          : ' + (pwsh || '(nao encontrado)'));
    log('  modo                : ' + (isPostinstall ? 'postinstall (npm install -g .)' :
                                       isForce      ? 'force (npm run install:force / --force)'
                                                    : 'simulacao (apenas relata)'));
    log('  env repassado:');
    const summary = envSummary(env);
    for (const k of Object.keys(summary)) log('    ' + k + '=' + summary[k]);
    log('');

    log('[opencode-orchestration] chamando: ' + (pwsh || 'pwsh') + ' ' + psArgs.join(' '));
    log('');

    try {
        await runPowerShell(pwsh, psArgs, env);
        log('');
        if (isForce) {
            log('[opencode-orchestration] instalacao efetivada.');
        } else {
            log('[opencode-orchestration] simulacao concluida.');
        }
        log('Para verificar: npm run verify (offline) ou npm run verify:net (com chamadas de API).');
    } catch (err) {
        warn('instalacao falhou: ' + err.message);
        process.exit(err.message.includes('exited') ? 1 : 3);
    }
}

main().catch((err) => {
    warn('erro fatal: ' + (err && err.message));
    process.exit(99);
});
