#!/usr/bin/env python3
"""Open Intelligent UI (Proxmox-Patch): Modell-Dropdown nachrüsten.

Idempotent, markerbasiert, versionstolerant:
- legt src/app/api/models/route.ts aus patches/models-route.ts an
- legt patches/available-models.json als patches/available-models.json ab
  (wird von der models-Route gelesen)
- erweitert src/app/api/chat/route.ts um ein optionales `model`-Feld
  im Request-Body (nur für Direct/OpenRouter-Betrieb, allowlist-geprüft)
- erweitert src/app/page.tsx um <ModelPicker /> (Dropdown + fetch-Wrapper,
  speichert die Wahl in localStorage `oiu-model`)

Läuft im Container im App-Root (/opt/open-intelligent-ui). Scheitert NIE
hart: Unbekannte Upstream-Stände erzeugen nur eine Warnung, der Build läuft
unverändert weiter.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parent
# Das Script liegt in <app>/patches/ → App-Root ist der Parent.
# (Auch ohne package.json, z. B. vor dem Clone.)
if APP_ROOT.name == "patches":
    APP_ROOT = APP_ROOT.parent

CHAT_ROUTE = APP_ROOT / "src" / "app" / "api" / "chat" / "route.ts"
PAGE = APP_ROOT / "src" / "app" / "page.tsx"
MODELS_ROUTE = APP_ROOT / "src" / "app" / "api" / "models" / "route.ts"

CHAT_MARK = "// OIU-MODEL-OVERRIDE"
PAGE_MARK = "// OIU-MODEL-PICKER"


def warn(msg: str) -> None:
    print(f"[model-picker] WARN: {msg}", flush=True)


def ok(msg: str) -> None:
    print(f"[model-picker] OK: {msg}", flush=True)


def install_models_route() -> None:
    src_candidates = [
        APP_ROOT / "patches" / "models-route.ts",
        Path(__file__).resolve().parent / "models-route.ts",
    ]
    src = next((p for p in src_candidates if p.exists()), None)
    if src is None:
        warn("patches/models-route.ts fehlt – /api/models wird nicht angelegt.")
        return
    MODELS_ROUTE.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, MODELS_ROUTE)
    ok("/api/models-Route angelegt.")


def patch_chat_route() -> None:
    if not CHAT_ROUTE.exists():
        warn(f"{CHAT_ROUTE} fehlt – Chat-Override übersprungen.")
        return
    text = CHAT_ROUTE.read_text(encoding="utf-8")
    if CHAT_MARK in text:
        ok("Chat-Route bereits gepatcht (Marker vorhanden).")
        return

    anchor = "as { messages?: unknown }).messages)"
    if anchor not in text:
        warn("Chat-Routen-Anker nicht gefunden (Upstream geändert?) – Override übersprungen.")
        return
    text = text.replace(
        "input = toInput((JSON.parse(raw) as { messages?: unknown }).messages);",
        "input = toInput((JSON.parse(raw) as { messages?: unknown }).messages);\n"
        f"  {CHAT_MARK}-START\n"
        "  // Proxmox-Patch: optionales Modell aus dem Body (Dropdown).\n"
        "  // Nur im Direct-Betrieb (OpenRouter/Ollama); Cloud/Gateway bleibt fix.\n"
        "  let requestedModel: string | null = null;\n"
        "  try {\n"
        '    const m = (JSON.parse(raw) as { model?: unknown }).model;\n'
        "    if (typeof m === \"string\" && m.length > 0 && m.length <= 128\n"
        "      && /^[A-Za-z0-9_.\\/:-]+$/.test(m)) requestedModel = m;\n"
        "  } catch { requestedModel = null; }\n"
        "  const activeDirectModel =\n"
        "    requestedModel ?? (direct ? direct.model ?? \"\" : \"\");\n"
        f"  {CHAT_MARK}-END",
        1,
    )
    # Nur der Direct-Call nutzt das wählbare Modell (ein Vorkommen im
    # chat.completions.create-Block). Der Cloud-Call behält backend.model.
    direct_anchor = "messages: [{ role: \"system\", content: backend.instructions }, ...toChatMessages(input)],"
    if direct_anchor in text:
        text = text.replace(
            "              {\n"
            "                model: backend.model,\n"
            f"                {direct_anchor}",
            "              {\n"
            f"                model: activeDirectModel || backend.model, {CHAT_MARK}\n"
            f"                {direct_anchor}",
            1,
        )
        ok("Chat-Route: Modell-Override für Direct-Betrieb aktiv.")
    else:
        warn("Direct-Call-Anker nicht gefunden – nur Body-Parsing eingefügt.")
    CHAT_ROUTE.write_text(text, encoding="utf-8")


def patch_page() -> None:
    if not PAGE.exists():
        warn(f"{PAGE} fehlt – Dropdown übersprungen.")
        return
    text = PAGE.read_text(encoding="utf-8")
    if PAGE_MARK in text:
        ok("page.tsx bereits gepatcht (Marker vorhanden).")
        return

    import_anchor = 'import { responseTheme } from "@/lib/response-theme";'
    if import_anchor not in text:
        warn("page.tsx-Import-Anker fehlt – Dropdown übersprungen.")
        return
    picker_code = (
        f'{import_anchor}\n'
        f'import {{ useEffect, useState }} from "react"; {PAGE_MARK}-IMPORT\n'
        f'{PAGE_MARK}-COMPONENT-START\n'
        'type ModelEntry = { id: string; label: string };\n'
        'function ModelPicker() {\n'
        '  const [models, setModels] = useState<ModelEntry[]>([]);\n'
        '  const [current, setCurrent] = useState<string>("");\n'
        '  useEffect(() => {\n'
        '    try {\n'
        '      const saved = window.localStorage.getItem("oiu-model") || "";\n'
        '      if (saved) setCurrent(saved);\n'
        '    } catch { /* ignore */ }\n'
        '    fetch("/api/models")\n'
        '      .then((r) => (r.ok ? r.json() : null))\n'
        '      .then((d) => {\n'
        '        if (!d) return;\n'
        '        if (Array.isArray(d.models)) setModels(d.models);\n'
        '        if (!window.localStorage.getItem("oiu-model") && d.defaultModel)\n'
        '          setCurrent(d.defaultModel);\n'
        '      })\n'
        '      .catch(() => { /* offline ok */ });\n'
        '    if (!(window as unknown as { __oiuFetchPatched?: boolean }).__oiuFetchPatched) {\n'
        '      (window as unknown as { __oiuFetchPatched?: boolean }).__oiuFetchPatched = true;\n'
        '      const origFetch = window.fetch.bind(window);\n'
        '      window.fetch = ((input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {\n'
        '        try {\n'
        '          const url = typeof input === "string" ? input : (input as Request).url || "";\n'
        '          const body = init?.body;\n'
        '          const chosen = window.localStorage.getItem("oiu-model");\n'
        '          if (url.includes("/api/chat") && chosen && typeof body === "string") {\n'
        '            const parsed = JSON.parse(body) as Record<string, unknown>;\n'
        '            if (parsed && !parsed.model) {\n'
        '              return origFetch(input, { ...init, body: JSON.stringify({ ...parsed, model: chosen }) });\n'
        '            }\n'
        '          }\n'
        '        } catch { /* ignore */ }\n'
        '        return origFetch(input, init);\n'
        '      }) as typeof fetch;\n'
        '    }\n'
        '  }, []);\n'
        '  if (!models.length) return null;\n'
        '  return (\n'
        '    <div style={{ display: "flex", justifyContent: "flex-end", padding: "8px 16px 0" }}>\n'
        '      <label style={{ fontSize: 12, opacity: 0.7, marginRight: 8, alignSelf: "center" }}>Modell</label>\n'
        '      <select\n'
        '        aria-label="Modell wählen"\n'
        '        value={current}\n'
        '        onChange={(e) => { setCurrent(e.target.value);\n'
        '          try { window.localStorage.setItem("oiu-model", e.target.value); } catch { /* ignore */ } }}\n'
        '        style={{ fontSize: 13, padding: "4px 8px", borderRadius: 8 }}>\n'
        '        {models.map((m) => (<option key={m.id} value={m.id}>{m.label}</option>))}\n'
        '      </select>\n'
        '    </div>\n'
        '  );\n'
        '}\n'
        f'{PAGE_MARK}-COMPONENT-END\n'
    )
    text = text.replace(import_anchor, picker_code, 1)

    shell_anchor = '<div className="chat-shell">'
    if shell_anchor not in text:
        warn("page.tsx-Shell-Anker fehlt – nur Komponente eingefügt.")
    else:
        text = text.replace(
            shell_anchor,
            f'{shell_anchor}\n      <ModelPicker /> {{/* {PAGE_MARK} */}}',
            1,
        )
    PAGE.write_text(text, encoding="utf-8")
    ok("page.tsx: Modell-Dropdown eingefügt.")


def main() -> int:
    install_models_route()
    patch_chat_route()
    patch_page()
    print("[model-picker] fertig.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
