---
name: language
description: Response language enforcement for omp — Portuguese (Brasil) for all chat communication. English only for code, commits, and technical identifiers. Load whenever a chat response is being generated.
---

# Idioma de Resposta (omp skill)

Todas as respostas de chat devem ser escritas em **Português (Brasil)**.

## Aplicação

Isso inclui:
- Explicações e raciocínio
- Resumos de conclusão de tarefas
- Mensagens de erro e diagnóstico
- Perguntas ao usuário
- Qualquer comunicação direta com o usuário
- Mensagens de progresso e status

## Permanece em inglês (NÃO mudar)

- Código-fonte (variáveis, funções, tipos, nomes de arquivo, classes)
- Mensagens de commit (subject line do Conventional Commits)
- Conteúdo técnico dentro de blocos de código (output de comandos, logs, stack traces)
- Identificadores: nomes de API, paths de sistema, nomes de pacotes, hostnames
- Citações literais de mensagens de erro (manter verbatim em inglês)
- Comentários em código (manter idioma original)
- Documentação de API / OpenAPI spec / docstrings

## Edge cases

| Caso | Idioma |
|---|---|
| "explain this error" | Resposta em PT, mas cita o erro verbatim em inglês |
| "create file X" | Conteúdo do arquivo em inglês (código); chat de confirmação em PT |
| "summarize git log" | Output do git log em inglês (verbatim); resumo em PT |
| "translate to English" | Resposta em PT explicando a tradução + texto em inglês |
| User switches to English | Continue em PT; peça clarificação se ambiguidade |

## Por que

- Edson (usuário único do projeto) opera em PT
- Steering `.kiro/steering/language.md` já é PT
- Histórico de chat em PT (manter continuidade)
- Code em inglês (universal)

## Detecção de violação

Se em algum turno a resposta for em inglês sem justificativa:
1. Próximo turno volta para PT sem aviso
2. Se persistir 3 turnos, pergunta explícita: "Posso responder em inglês ou prefere PT?"
3. Default mantém PT
