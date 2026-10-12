# open-intelligent-ui auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

> Upstream-App: `https://github.com/thesysdev/open-intelligent-ui` (Next.js, Node ≥ 24)
> Dieser Ordner enthält Installer (`install/`), systemd-Unit (`systemd/`) und Modell-Dropdown-Patches (`patches/`).
> Der Upstream-Code selbst wird **nicht** geforkt – der Installer klont ihn frisch in den Container und wendet die Patches idempotent an.

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Open-Intelligent-UI/main/install/open-intelligent-ui.sh)"
```

> Per Env-Override auf ein anderes Repo zeigen (ohne Script zu ändern):
> ```bash
> RAW_BASE=https://raw.githubusercontent.com/DEIN/REPO/main bash -c "$(wget -qLO - https://raw.githubusercontent.com/DEIN/REPO/main/install/open-intelligent-ui.sh)"
> ```

Mit OpenRouter-Key + Wunschmodell direkt:

```bash
OPENROUTER_API_KEY=sk-or-... LLM_MODEL=openai/gpt-6.1-sol bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Open-Intelligent-UI/main/install/open-intelligent-ui.sh)"
```

Anpassungen per Umgebungsvariable oder Flag (ID immer **nächste freie**, außer gesetzt):

```bash
CT_ID=150 CORES=2 RAM=4096 DISK=12 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Open-Intelligent-UI/main/install/open-intelligent-ui.sh)"
bash open-intelligent-ui.sh --ctid 150 --cores 2 --memory 4096 --disk 12 --bridge vmbr0 --openrouter-key sk-or-... --model anthropic/claude-sonnet-4.5 --storage local-lvm
bash open-intelligent-ui.sh --no-picker   # Upstream pur, ohne Modell-Dropdown
bash open-intelligent-ui.sh --debug       # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/open-intelligent-ui-install-*.log
```

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `open-intelligent-ui` |
| Zweck | Open-Source „Intelligent UI" (ChatGPT-Feature-Nachbau): interaktive Antworten statt Text (Karten, Charts, Tabellen) |
| Tech-Stack | Next.js 16 + Node 24 (`:3000`), `next start -H 0.0.0.0`, User `oiu`, App unter `/opt/open-intelligent-ui` |
| Upstream-Repo | `https://github.com/thesysdev/open-intelligent-ui` |
| Modellbetrieb | Standard **OpenRouter** (`LLM_BASE_URL=https://openrouter.ai/api/v1` + Key + Modell), **Dropdown in der Web UI** (alle OpenRouter-Modelle via `/api/models`, Wahl in localStorage, pro Request an `/api/chat`); alternativ Thesys-Cloud oder Ollama per `.env` |
| Web UI | `http://<LXC-IP>:3000` (Dropdown oben rechts) |
| Standard-Ressourcen | 2 vCPU / 4096 MB RAM / 12 GB Disk (Next-Build braucht RAM; mehr bei Ollama-Modellen) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | **unprivilegiert** (`--unprivileged 1`), `nesting=1`, `onboot: 1` |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `open-intelligent-ui` (`onboot: 1`, unprivilegiert),
3. installiert im Container Node 24 (Nodesource) + git + python3, legt User `oiu` an, klont den Upstream, wendet den Modell-Picker-Patch an (idempotent, warnt statt abzubrechen), schreibt `.env` (OpenRouter), baut (`npm ci` + `npm run build`), schreibt `open-intelligent-ui.service`, `systemctl enable --now open-intelligent-ui`,
4. verifiziert `systemctl is-active open-intelligent-ui` + HTTP auf `localhost:3000/` und gibt die finale URL + Container-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active open-intelligent-ui = active).
[OK]    Web UI antwortet (HTTP 200 auf localhost:3000/).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : open-intelligent-ui – Open-Source Intelligent UI (Next.js)
  Upstream     : https://github.com/thesysdev/open-intelligent-ui
  Container    : CT 100 (Hostname: open-intelligent-ui, unprivilegiert, onboot=1)
  Ressourcen   : 2 vCPU / 4096 MB RAM / 12 GB Disk
  Web UI       : http://192.168.1.100:3000  (Modell-Dropdown oben rechts)
  Standardmodell: openai/gpt-6.1-sol (per Dropdown zur Laufzeit wechselbar, alle OpenRouter-Modelle via /api/models)
  ...
  Log          : /tmp/open-intelligent-ui-install-2026-....log
══════════════════════════════════════════════════════════
```

## Modellwechsel

- **In der Web UI:** Dropdown oben rechts – listet live alle OpenRouter-Modelle (mit Key) oder die kuratierte Liste (`patches/available-models.json`, 20 Modelle).
- **Persistent (Server-Default):** `pct exec <CT> -- nano /opt/open-intelligent-ui/.env` (`LLM_MODEL=...`), dann `pct exec <CT> -- systemctl restart open-intelligent-ui`.
- **Key nachtragen** (falls ohne installiert): gleiche `.env` (`LLM_API_KEY=...`), dann Restart. Ohne Key antwortet `/api/chat` mit HTTP 500 + Hinweis.
- **Ollama statt Cloud** (viel RAM nötig, z. B. 8 GB+ für `qwen3:8b`, 32 GB für `qwen3.8:27b`): in `.env` die `LLM_*`-Zeilen auskommentieren und setzen:
  ```text
  MODEL_PROVIDER=ollama
  OLLAMA_MODEL=qwen3:8b
  ```
  Ollama separat installieren (`curl -fsSL https://ollama.com/install.sh | sh`, `OLLAMA_CONTEXT_LENGTH=32768 ollama serve`, Modell pullen) – siehe Upstream-README.

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active open-intelligent-ui
curl -fs http://<LXC-IP>:3000/ -o /dev/null && echo WEB_UI_OK
```

## Update / Deinstall

```bash
bash open-intelligent-ui.sh --ctid 100            # Update: idempotent (Upstream-Refresh + Patch + Rebuild + Restart)
pct stop 100 && pct destroy 100                   # Deinstall
```

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code aus, Voll-Log unter `/tmp/open-intelligent-ui-install-*.log`.
- `bash open-intelligent-ui.sh --debug` für `bash -x`-Trace.
- Im Container: `systemctl status open-intelligent-ui --no-pager`, `journalctl -u open-intelligent-ui -n 100`.
- Build-Fehler nach Upstream-Update: Patch-Script warnt nur (`[model-picker] WARN`), der Build läuft mit Upstream pur weiter – ggf. Issue mit Log-Auszug aufmachen.
- `npm ci`-Fehler bei Node < 24: Installer installiert Node 24 via Nodesource automatisch nach.

## Dateien

- `install/open-intelligent-ui.sh` – Proxmox-Einzeiler (Host, root).
- `systemd/open-intelligent-ui.service` – Unit (`:3000`, `After=network-online.target`, `Restart=always`, `EnvironmentFile=/opt/open-intelligent-ui/.env`).
- `patches/available-models.json` – kuratierte Modelliste fürs Dropdown (Fallback ohne Key).
- `patches/models-route.ts` – `/api/models`-Route (live OpenRouter-Liste oder Fallback).
- `patches/apply-model-picker.py` – idempotenter Patch (Chat-Override + Dropdown, warnt statt abzubrechen).
