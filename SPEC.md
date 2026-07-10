# DevSpaces — sidebar/controle nativo do Ghostty para workspaces DevSync

## Visão
Um app macOS (SwiftUI, janela estreita tipo sidebar) que é o "controle" do
Ghostty: lista os workspaces (projetos DevSync) com cor, estado e uso dos
agentes; clique abre/foca a aba nativa correspondente no Ghostty; um editor
visual configura, por workspace: cor, quantidade de splits, e comando/modelo
de cada split.

O Ghostty continua sendo o terminal real. O app manda nele via
`/Users/Raphael/bin/devworkspace` (que já sabe abrir/focar abas via
AppleScript e criar splits/tmux).

## Arquivos e papéis

| Arquivo | Papel | Quem escreve |
|---|---|---|
| `~/.config/dev-workspaces/workspaces.json` | FONTE DA VERDADE da configuração | o app (e humanos) |
| `~/.config/dev-workspaces/workspaces.zsh` | GERADO a partir do JSON — consumido pelo devworkspace | `devworkspace generate` |
| `~/devspaces/generate_workspaces.py` | gerador JSON→zsh (python3 do sistema) | Codex |
| `~/bin/devworkspace` | runtime (já existe) + novos subcomandos `generate`, `states` + cor | Codex (edições pontuais) |
| `~/devspaces/DevSpaces.swift` | app SwiftUI single-file | Opus |
| `~/devspaces/build.zsh` | compila e monta `~/Applications/DevSpaces.app` | Codex |

## Schema do workspaces.json

```json
{
  "autostart_agents": false,
  "default_model": "",
  "workspaces": [
    {
      "name": "pnt",
      "color": "#89b4fa",
      "panes": [
        {"name": "shell",  "command": "shell",  "model": "",       "direction": "", "parent": ""},
        {"name": "codex",  "command": "codex",  "model": "",       "direction": "right", "parent": "shell"},
        {"name": "opus",   "command": "claude", "model": "opus",   "direction": "down",  "parent": "shell"},
        {"name": "sonnet", "command": "claude", "model": "sonnet", "direction": "down",  "parent": "codex"}
      ]
    }
  ]
}
```

Regras:
- O primeiro pane é sempre o raiz: `name` livre (convenção: `shell`),
  `direction`/`parent` vazios.
- `command`: `shell` | `claude` | `codex` | `codex2` | string arbitrária
  (ex.: `pnpm dev`). `model` só tem efeito para `claude`/`codex`/`codex2`.
- `direction`: `right` | `left` | `down` | `up`. `parent`: nome de um pane
  declarado antes.
- Nomes de pane: sem `:`, `,`, espaço ou newline (viram nome de sessão tmux).
- Projetos registrados no DevSync (`~/.devsync/projects`, formato
  `nome|path`) que não estiverem no JSON aparecem no app com um template
  default (os 4 panes acima, cor cinza `#6c7086`) e são acrescentados ao JSON
  ao salvar.

## Gerador (generate_workspaces.py)

- Lê o JSON, valida (nomes de pane, direções, parent existente, primeiro pane
  raiz), e escreve `workspaces.zsh` ATOMICAMENTE (temp + rename) no formato:

```zsh
# GERADO por devspaces a partir de workspaces.json — não edite à mão.
AUTOSTART_AGENTS=0
DEFAULT_MODEL=""
workspace pnt "" "#89b4fa"
pane pnt codex right shell codex
pane pnt opus down shell claude opus
pane pnt sonnet down codex claude sonnet
```

- `workspace <nome> <modelo-default> <cor>` (aspas sempre; cor pode ser "").
- O pane raiz NÃO vira linha `pane` (ele é implícito), MAS se o pane raiz
  tiver command != "shell", emitir `pane <proj> __root__ ...`? Não — o
  runtime só suporta raiz shell hoje; o gerador deve rejeitar command != shell
  no pane raiz com mensagem clara (validação).
- Em erro de validação: exit 1, mensagem legível em stderr, NÃO tocar no zsh.
- Se o JSON não existir: gerar a partir do template default com os projetos
  de `~/.devsync/projects` e também ESCREVER esse JSON inicial.

## devworkspace — mudanças (mínimas)

1. `workspace()` aceita 3º argumento cor → `WS_COLORS[$project]`.
2. `apply_pane_status`: usar a cor do workspace no nome do projeto do
   status-left (fallback: `#cdd6f4`).
3. Novo subcomando `generate`: roda
   `/usr/bin/python3 ~/devspaces/generate_workspaces.py` e propaga o exit code.
4. Novo subcomando `states`: imprime uma linha por projeto registrado:
   `nome|local|tab` onde `local` = `ready`/`not-local`; `tab` = `aberto`
   (aba Ghostty com esse nome existe — usar open_tab_names UMA vez), `fundo`
   (sessão tmux `ghostty-<nome>-<pane-raiz>` existe), senão `fechado`.
   Deve ser rápido (1 osascript no total) — o app chama a cada poll.
5. Não quebrar nada existente: picker, ws, run-pane, usage continuam iguais.
   ATENÇÃO (armadilhas já descobertas neste código): nunca `local path` em
   zsh (mascara PATH — usar `pdir`); AppleScript `select tab`/`close tab`
   exigem variável (`select tab theTab`), nunca literal `tab 1 of ...`;
   handlers `on run argv` em `osascript -e` exigem `end run` explícito.

## App SwiftUI (DevSpaces.swift)

- macOS 14+, single file, sem dependências externas. Janela estreita
  (~300–340pt), altura livre, dark-friendly (segue o sistema), estilo sidebar.
- Lista de workspaces: barra/bolinha da cor configurada, nome, estado
  (`aberto` verde / `fundo` amarelo / `fechado` cinza / `não está neste Mac`
  esmaecido e não clicável), resumo dos splits ("4 splits · codex · opus ·
  sonnet"). Clique na linha → abre/foca (shell out `devworkspace ws <nome>`
  em fila background) e traz o Ghostty pra frente (`open -a Ghostty` se não
  estiver rodando).
- Seção de uso (embaixo): parse de `devworkspace usage` (formato plain:
  `claude   5h 24%   7d 5%` por linha; `(sem dados)` possível). Barras de
  progresso coloridas: <50 verde, <80 amarelo, ≥80 vermelho. Poll: 60 s.
- Poll de estados: `devworkspace states` a cada 5 s (e imediatamente após
  abrir workspace). Nunca bloquear a main thread.
- Botão de engrenagem por workspace → sheet de edição:
  - ColorPicker (grava hex).
  - Editor de panes: linha por pane — nome, comando (menu: shell/claude/
    codex/codex2/custom + campo texto se custom), modelo (campo texto,
    placeholder "default"), direção (menu right/down/left/up), parent (menu
    com panes anteriores). Adicionar/remover pane (o raiz não é removível
    nem tem direção/parent). Validação leve na UI (nomes válidos, parent
    anterior).
  - Salvar → grava JSON (pretty, atômico), roda `devworkspace generate`;
    se exit != 0 mostrar o stderr num alerta e NÃO fechar o sheet.
  - Aviso no rodapé do sheet: "abas já abertas só aplicam o novo layout
    depois de fechadas e reabertas".
- Toggle global "auto-iniciar agentes" (grava `autostart_agents` + generate).
- Extras de sidebar: toggle "manter por cima" (NSWindow.level .floating);
  lembrar posição/tamanho (frameAutosaveName).
- Todos os shell-outs: `Process` com caminho absoluto
  `/Users/Raphael/bin/devworkspace`, nunca na main thread; capturar stdout+
  stderr.
- Identidade: bundle id `com.raphael.devspaces`, nome "DevSpaces".

## Build (build.zsh)

- `swiftc -O DevSpaces.swift -o DevSpaces` (target arm64 macOS 14) e montar
  bundle `~/Applications/DevSpaces.app`:
  - `Contents/MacOS/DevSpaces`, `Contents/Info.plist` com CFBundleIdentifier
    `com.raphael.devspaces`, CFBundleName DevSpaces, LSMinimumSystemVersion
    14.0, `NSAppleEventsUsageDescription` ("DevSpaces controla o Ghostty para
    abrir e focar workspaces.").
  - `codesign --force --sign - <app>` (ad-hoc) para o TCC de automação
    funcionar de forma estável.
- Idempotente (re-rodar substitui o app).

## Critérios de aceite

1. `python3 generate_workspaces.py` com o JSON inicial → `workspaces.zsh`
   equivalente ao atual (mesmos panes/modelos) + cores.
2. `devworkspace validate` OK com o zsh gerado; `devworkspace list` mostra os
   panes; barra tmux usa a cor do workspace.
3. `devworkspace states` responde em <1 s com os 6 projetos.
4. `build.zsh` produz `~/Applications/DevSpaces.app` que abre, lista os
   workspaces com cor/estado/uso, clique abre/foca a aba no Ghostty, e o
   editor salva JSON→generate sem quebrar o runtime.

## ADENDO v2 (2026-07-10) — layout por sequência

O usuário não quer direção/parent. Esquema novo:
- No JSON, cada pane precisa só de `name`, `command`, `model` (direction/
  parent são ignorados pelo gerador se presentes). O split 1 PODE ser agente.
- O gerador calcula o layout pela ORDEM: n=1 tela inteira; n>=2 duas fileiras
  — em cima floor(n/2), embaixo o resto (ímpar deixa menos splits em cima).
  Emite `root <proj> <nome> <cmd> <modelo>` quando o split 1 não é o shell
  padrão, e `pane` com direção/parent calculados.
- Runtime: novo DSL `root`; raiz não é mais hardcoded "shell";
  `equalize_splits` é executado após criar os splits; `ensure_ghostty_window`
  abre o Ghostty e espera janela antes de criar aba.
- App: sheet sem direção/parent — cartões ordenados (programa+modelo, ▲▼,
  lixeira), nomes auto-gerados, preview ao vivo do layout com retângulos
  numerados.
