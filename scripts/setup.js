#!/usr/bin/env node
/*
 * setup.js — bin entry: `opencode-orchestration` ou `setup-orchestration`.
 *
 * Apenas wrapper sobre install.js. Mantem-se separado para dar semantica
 * ao binario (instalacao/setup explicito), enquanto install.js e o
 * gancho de lifecycle do npm.
 */

require('./install.js');
