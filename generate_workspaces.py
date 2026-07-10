#!/usr/bin/env python3
"""Gera ~/.config/dev-workspaces/workspaces.zsh a partir de workspaces.json.

O JSON é a fonte da verdade (editado pelo app DevSpaces). O zsh gerado é o
que o runtime ~/bin/devworkspace consome. Validação estrita: em erro, nada é
escrito e o exit code é 1.
"""

import json
import os
import sys
import tempfile

HOME = os.path.expanduser("~")
CONFIG_DIR = os.path.join(HOME, ".config", "dev-workspaces")
JSON_PATH = os.path.join(CONFIG_DIR, "workspaces.json")
ZSH_PATH = os.path.join(CONFIG_DIR, "workspaces.zsh")
PROJECTS_PATH = os.path.join(HOME, ".devsync", "projects")

VALID_DIRECTIONS = {"right", "left", "down", "up"}
KNOWN_COMMANDS = {"shell", "claude", "codex", "codex2"}
DEFAULT_COLOR = "#6c7086"
DEFAULT_PANES = [
    {"name": "shell", "command": "shell", "model": "", "direction": "", "parent": ""},
    {"name": "codex", "command": "codex", "model": "", "direction": "right", "parent": "shell"},
    {"name": "opus", "command": "claude", "model": "opus", "direction": "down", "parent": "shell"},
    {"name": "sonnet", "command": "claude", "model": "sonnet", "direction": "down", "parent": "codex"},
]


def fail(msg):
    print(f"generate_workspaces: {msg}", file=sys.stderr)
    sys.exit(1)


def valid_pane_name(name):
    if not name or not isinstance(name, str):
        return False
    return not any(c in name for c in (":", ",", "|", " ", "\n", "\t"))


def registered_projects():
    names = []
    try:
        with open(PROJECTS_PATH, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                names.append(line.split("|", 1)[0])
    except OSError:
        pass
    return names


def default_json():
    return {
        "autostart_agents": False,
        "default_model": "",
        "workspaces": [
            {"name": name, "color": DEFAULT_COLOR, "panes": [dict(p) for p in DEFAULT_PANES]}
            for name in registered_projects()
        ],
    }


def load_or_bootstrap_json():
    if not os.path.exists(JSON_PATH):
        data = default_json()
        atomic_write(JSON_PATH, json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        return data
    try:
        with open(JSON_PATH, encoding="utf-8") as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        fail(f"JSON inválido em {JSON_PATH}: {e}")
    except OSError as e:
        fail(f"não consegui ler {JSON_PATH}: {e}")


def validate(data):
    if not isinstance(data, dict):
        fail("o JSON raiz precisa ser um objeto")
    workspaces = data.get("workspaces")
    if not isinstance(workspaces, list):
        fail("campo 'workspaces' ausente ou não é lista")

    seen_ws = set()
    for ws in workspaces:
        if not isinstance(ws, dict):
            fail("cada workspace precisa ser um objeto")
        name = ws.get("name")
        if not valid_pane_name(name):
            fail(f"nome de workspace inválido: {name!r}")
        if name in seen_ws:
            fail(f"workspace duplicado: {name}")
        seen_ws.add(name)

        color = ws.get("color", "")
        if color and (not color.startswith("#") or len(color) != 7):
            fail(f"[{name}] cor inválida: {color!r} (use hex de 6 dígitos tipo #89b4fa)")

        panes = ws.get("panes")
        if not isinstance(panes, list) or not panes:
            fail(f"[{name}] precisa de ao menos 1 split")

        seen_panes = []
        for pane in panes:
            pname = pane.get("name")
            if not valid_pane_name(pname):
                fail(f"[{name}] nome de pane inválido: {pname!r}")
            if pname in seen_panes:
                fail(f"[{name}] pane duplicado: {pname}")
            command = pane.get("command", "shell")
            if not isinstance(command, str) or not command.strip():
                fail(f"[{name}][{pname}] comando vazio")
            seen_panes.append(pname)


def zsh_quote(s):
    return "'" + str(s).replace("'", "'\\''") + "'"


def layout(panes):
    """Posição automática pela ORDEM dos splits (direction/parent do JSON são
    ignorados). n=1: tela inteira; n>=2: duas fileiras — em cima floor(n/2),
    embaixo o resto (ímpar deixa a fileira de cima com menos splits, cada um
    mais largo). Retorna [(pane, direction, parent_name)] para os splits 2..n.
    """
    n = len(panes)
    if n < 2:
        return []
    top = max(1, n // 2)
    names = [p["name"] for p in panes]
    placed = []
    # 1º: divide a aba em duas fileiras ENQUANTO a raiz ainda ocupa a largura
    # toda — o primeiro da fileira de baixo nasce do raiz, pra baixo. Se essa
    # divisão viesse depois dos splits horizontais, o "down" cortaria só o
    # retângulo da raiz e os vizinhos ficariam com a altura inteira da aba.
    placed.append((panes[top], "down", names[0]))
    # 2º: completa a fileira de cima, cada um à direita do anterior
    for i in range(1, top):
        placed.append((panes[i], "right", names[i - 1]))
    # 3º: completa a fileira de baixo, cada um à direita do anterior
    for j in range(top + 1, n):
        placed.append((panes[j], "right", names[j - 1]))
    return placed


def render(data):
    lines = [
        "# GERADO pelo DevSpaces a partir de workspaces.json — não edite à mão.",
        "# Edite pelo app DevSpaces ou em ~/.config/dev-workspaces/workspaces.json",
        "# e rode `devworkspace generate`.",
        "",
        f"AUTOSTART_AGENTS={1 if data.get('autostart_agents') else 0}",
        f"DEFAULT_MODEL={zsh_quote(data.get('default_model', ''))}",
        "",
    ]
    for ws in data["workspaces"]:
        name = ws["name"]
        color = ws.get("color", "")
        model = ws.get("model", "")
        panes = ws["panes"]
        lines.append(f"workspace {zsh_quote(name)} {zsh_quote(model)} {zsh_quote(color)}")

        root = panes[0]
        if (
            root["name"] != "shell"
            or root.get("command", "shell") != "shell"
            or root.get("model", "")
            or root.get("effort", "")
        ):
            lines.append(
                "root "
                + " ".join(
                    zsh_quote(x)
                    for x in (
                        name,
                        root["name"],
                        root.get("command", "shell"),
                        root.get("model", ""),
                        root.get("effort", ""),
                    )
                )
            )

        for pane, direction, parent in layout(panes):
            lines.append(
                "pane "
                + " ".join(
                    zsh_quote(x)
                    for x in (
                        name,
                        pane["name"],
                        direction,
                        parent,
                        pane.get("command", "shell"),
                        pane.get("model", ""),
                        pane.get("effort", ""),
                    )
                )
            )
        lines.append("")
    return "\n".join(lines)


def atomic_write(dest, content):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest), prefix=".gen-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp, dest)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main():
    data = load_or_bootstrap_json()
    validate(data)
    atomic_write(ZSH_PATH, render(data))
    print(f"ok: {ZSH_PATH} gerado com {len(data['workspaces'])} workspaces")


if __name__ == "__main__":
    main()
