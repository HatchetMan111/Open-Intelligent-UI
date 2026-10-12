#!/usr/bin/env bash
#
# open-intelligent-ui Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      open-intelligent-ui – Open-Source "Intelligent UI" (ChatGPT-Feature-Nachbau)
# Upstream: https://github.com/thesysdev/open-intelligent-ui (Next.js, Node >= 24)
# Stack:    Next.js (:3000) via Node 24, ohne Docker. Standard OpenRouter
#           (LLM_BASE_URL/LLM_API_KEY/LLM_MODEL), optional Thesys-Cloud oder Ollama.
#           Modell-Dropdown: Patch (patches/) legt /api/models an und erweitert
#           /api/chat um ein optionales `model`-Feld + Dropdown in der Chat-Seite.
# Host:     DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Open-Intelligent-UI/main/install/open-intelligent-ui.sh)"
#   OPENROUTER_API_KEY=sk-or-... LLM_MODEL=openai/gpt-6.1-sol bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Open-Intelligent-UI/main/install/open-intelligent-ui.sh)"
#   bash open-intelligent-ui.sh --ctid 150 --cores 2 --memory 4096 --disk 12 --openrouter-key sk-or-... --model openai/gpt-6.1-sol --debug
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="open-intelligent-ui"                     # Container-Hostname + Service-Name
APP_PORT="3000"                               # Web-UI (Next.js, bind 0.0.0.0)
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/thesysdev/open-intelligent-ui}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
# Per RAW_BASE-Env auf ein anderes Repo zeigen (ohne Script zu ändern).
INSTALLER_REPO="${INSTALLER_REPO:-https://github.com/HatchetMan111/Open-Intelligent-UI}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/Open-Intelligent-UI/main}"
SERVICE_URL="${SERVICE_URL:-$RAW_BASE/systemd/open-intelligent-ui.service}"
PATCH_PY_URL="${PATCH_PY_URL:-$RAW_BASE/patches/apply-model-picker.py}"
MODELS_ROUTE_URL="${MODELS_ROUTE_URL:-$RAW_BASE/patches/models-route.ts}"
MODELS_JSON_URL="${MODELS_JSON_URL:-$RAW_BASE/patches/available-models.json}"

DEFAULT_CORES="2"                             # vCPU (Next-Build braucht 2)
DEFAULT_RAM="4096"                            # RAM in MB (Next-Build + Laufzeit)
DEFAULT_SWAP="1024"                           # Swap (MB)
DEFAULT_DISK="12"                             # Disk in GB (OS + node_modules + .next)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                # Storage für CT-Templates
DEFAULT_OS="debian-12-standard"               # Template-Familie
UNPRIVILEGED="1"                              # 1 = unprivilegiert (reicht hier)
FEATURES="nesting=1"                          # nesting für Node/npm-Robustheit
DEFAULT_MODEL="openai/gpt-6.1-sol"            # OpenRouter-Modell (Dropdown-Default)
DEFAULT_REASONING="low"                       # low = ~5x schnelleres erstes UI-Token
WITH_PICKER_DEFAULT="1"                       # 1 = Modell-Dropdown-Patch anwenden

APP_USER="oiu"
APP_DIR="/opt/open-intelligent-ui"

# Umgebungs-Overrides: CT_ID=150 CORES=2 RAM=4096 DISK=12 OPENROUTER_API_KEY=... ./open-intelligent-ui.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"
OPENROUTER_KEY_ARG="${OPENROUTER_API_KEY:-${LLM_API_KEY:-}}"
MODEL_ARG="${LLM_MODEL:-${MODEL:-$DEFAULT_MODEL}}"
REASONING_ARG="${LLM_REASONING_EFFORT:-$DEFAULT_REASONING}"
WITH_PICKER_ARG="${WITH_MODEL_PICKER:-$WITH_PICKER_DEFAULT}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollständige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Vollständiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash open-intelligent-ui.sh [OPTIONEN]
  OPENROUTER_API_KEY=sk-or-... bash open-intelligent-ui.sh
  bash -c "\$(wget -qLO - ${RAW_BASE}/install/open-intelligent-ui.sh)"

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufällig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
  --openrouter-key K   OpenRouter API-Key (oder Env OPENROUTER_API_KEY)
  --model ID           OpenRouter-Modell (Default: ${DEFAULT_MODEL}, im Dropdown änderbar)
  --reasoning E        Reasoning-Effort low/medium/high/default (Default: ${DEFAULT_REASONING})
  --no-picker          Modell-Dropdown-Patch überspringen (Upstream pur)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CT_ID="$CT_ID_ARG" HOSTNAME_ARG="$APP" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="" TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE" BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG="" SSH_KEY_ARG=""
OPENROUTER_KEY="$OPENROUTER_KEY_ARG" MODEL="$MODEL_ARG" REASONING="$REASONING_ARG"
WITH_PICKER="$WITH_PICKER_ARG"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --openrouter-key) OPENROUTER_KEY="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;;
    --reasoning) REASONING="$2"; shift 2;;
    --no-picker) WITH_PICKER="0"; shift;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Host-Prüfung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausführen."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }

# Immer nächste freie ID, außer --ctid gesetzt
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "Nächste freie CT-ID: $CT_ID"
fi

# RootFS-Storage: Argument > local-lvm (wenn vorhanden) > erstes verfügbares
if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content rootdir | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein RootFS-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Template-Store: $TEMPLATE_STORE | Bridge: $BRIDGE"

if [[ -z "$OPENROUTER_KEY" ]]; then
  msg_warn "Kein OpenRouter-Key gesetzt (OPENROUTER_API_KEY/--openrouter-key)."
  msg_warn "Der Container wird trotzdem gebaut; Key danach nachtragen:"
  msg_warn "  pct exec $CT_ID -- nano $APP_DIR/.env && pct exec $CT_ID -- systemctl restart $APP"
fi

# ---------------------------------------------------------------------------
# 2. Template sicherstellen (neuestes debian-12-standard)
# ---------------------------------------------------------------------------
msg_info "Prüfe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Templates."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
# Hinweis: Proxmox liefert Templates heute als .tar.zst (nicht nur .tar.gz/.tar.xz).
TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template – suche neuestes Debian-Standard-Template als Fallback ..."
  TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_error "Kein Debian-Standard-Template gefunden. Verfügbare System-Templates:"
  printf '%s\n' "$AVAILABLE_TEMPLATES" | head -n 20 >&2 || true
  msg_error "Bitte 'pveam update' manuell prüfen (Netz/DNS auf dem Host)."
  exit 1
fi
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Lade Template $TEMPLATE ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template bereit: $TEMPLATE_STORE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, wird aktualisiert)
# ---------------------------------------------------------------------------
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT $CT_ID existiert – überspringe Erstellung (Update-Modus)."
else
  [[ -z "$PASSWORD_ARG" ]] && PASSWORD_ARG="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  msg_info "Erstelle CT $CT_ID ($HOSTNAME_ARG): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 --start 0 \
    --password "$PASSWORD_ARG"
  msg_ok "CT $CT_ID erstellt (unprivilegiert, nesting, onboot=1)."
fi

if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys 2>/dev/null \
    || { pct exec "$CT_ID" -- mkdir -p /root/.ssh; pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys; }
fi

pct start "$CT_ID" 2>/dev/null || true
msg_info "Warte auf Container-Netz ..."
CT_IP=""
for i in $(seq 1 24); do
  sleep 5
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${CT_IP:-}" ]] && break
done
[[ -n "${CT_IP:-}" ]] || { msg_error "Keine Container-IP (pct exec hostname -I). Netzwerk/Bridge prüfen."; exit 1; }
msg_ok "Container-IP: $CT_IP"

# ---------------------------------------------------------------------------
# 4. open-intelligent-ui im Container (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Installiere Basis + Node 24 im Container ..."
# Hinweis: äußere Single-Quotes – der Block läuft dadurch 1:1 im Container,
# ohne dass die Host-Shell $ oder $(...) anfasst (kein Escaping nötig).
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git curl ca-certificates python3
  if ! command -v node >/dev/null 2>&1 || ! node --version | grep -qE "^v(2[4-9]|[3-9][0-9])"; then
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
    apt-get install -y nodejs
  fi
  node --version
  npm --version
  id oiu >/dev/null 2>&1 || useradd -m -s /bin/bash oiu
  mkdir -p /opt/open-intelligent-ui/patches
  chown -R oiu:oiu /opt/open-intelligent-ui
'
# Hinweis: bewusst kein "| tail" hier – mit pipefail würde der trap sonst
# die Pipe (tail) statt des gescheiterten pct-Befehls melden. Voll-Output steht im Log.

msg_info "Hole App-Code (Upstream $UPSTREAM_REPO, Branch $UPSTREAM_BRANCH) ..."
pct exec "$CT_ID" -- env "UPSTREAM_REPO=$UPSTREAM_REPO" "UPSTREAM_BRANCH=$UPSTREAM_BRANCH" bash -c '
  set -euo pipefail
  if [ -d /opt/open-intelligent-ui/.git ]; then
    git -C /opt/open-intelligent-ui fetch --depth 1 origin "$UPSTREAM_BRANCH" || true
    git -C /opt/open-intelligent-ui reset --hard "origin/$UPSTREAM_BRANCH" || true
  else
    rm -rf /opt/open-intelligent-ui/src /opt/open-intelligent-ui/package.json
    git clone --depth 1 --branch "$UPSTREAM_BRANCH" "$UPSTREAM_REPO" /tmp/oiu-upstream
    cp -a /tmp/oiu-upstream/src /tmp/oiu-upstream/package.json /tmp/oiu-upstream/package-lock.json \
      /tmp/oiu-upstream/next.config.ts /tmp/oiu-upstream/tsconfig.json /opt/open-intelligent-ui/ 2>/dev/null || true
    rm -rf /tmp/oiu-upstream
  fi
  chown -R oiu:oiu /opt/open-intelligent-ui
  test -f /opt/open-intelligent-ui/package.json
'
msg_ok "App-Code ok (package.json vorhanden)."

# Patches aus diesem Repo übernehmen (fällt auf "ohne Picker" zurück)
if [[ "$WITH_PICKER" == "1" ]]; then
  msg_info "Übernehme Modell-Picker-Patches ..."
  if pct exec "$CT_ID" -- curl -fsSL -o /opt/open-intelligent-ui/patches/apply-model-picker.py "$PATCH_PY_URL" 2>/dev/null \
    && pct exec "$CT_ID" -- curl -fsSL -o /opt/open-intelligent-ui/patches/models-route.ts "$MODELS_ROUTE_URL" 2>/dev/null \
    && pct exec "$CT_ID" -- curl -fsSL -o /opt/open-intelligent-ui/patches/available-models.json "$MODELS_JSON_URL" 2>/dev/null; then
    msg_ok "Patches aus Repo übernommen."
    pct exec "$CT_ID" -- bash -c '
      set -euo pipefail
      cd /opt/open-intelligent-ui
      python3 patches/apply-model-picker.py || echo "WARN: Modell-Picker-Patch übersprungen (Upstream-Stand unbekannt) – App baut unverändert."
      chown -R oiu:oiu /opt/open-intelligent-ui
    '
  else
    msg_warn "Patch-URLs nicht erreichbar (RAW_BASE prüfen) – fahre ohne Dropdown fort."
  fi
else
  msg_info "Modell-Picker per --no-picker deaktiviert (Upstream pur)."
fi

# .env schreiben (idempotent: vorhandene Keys bleiben, OIU-Keys werden gesetzt)
msg_info "Schreibe .env (OpenRouter-Betrieb) ..."
TMP_ENV="$(mktemp)"
{
  echo "# Open Intelligent UI – Proxmox LXC (vom Installer verwaltet, weitere Keys in .env ergänzbar)"
  echo "LLM_BASE_URL=https://openrouter.ai/api/v1"
  echo "LLM_API_KEY=${OPENROUTER_KEY}"
  echo "LLM_MODEL=${MODEL}"
  echo "LLM_REASONING_EFFORT=${REASONING}"
  echo "PORT=3000"
  echo ""
  echo "# Alternativ: Thesys-Cloud statt OpenRouter (LLM_*-Zeilen dann entfernen):"
  echo "# THESYS_API_KEY="
  echo "# THESYS_MODEL=openai/gpt-6.1-sol"
  echo "# Alternativ: lokales Ollama statt Cloud (braucht viel RAM, siehe README):"
  echo "# MODEL_PROVIDER=ollama"
  echo "# OLLAMA_MODEL=qwen3.8:27b"
} > "$TMP_ENV"
pct push "$CT_ID" "$TMP_ENV" /opt/open-intelligent-ui/.env
rm -f "$TMP_ENV"
pct exec "$CT_ID" -- chown oiu:oiu /opt/open-intelligent-ui/.env
pct exec "$CT_ID" -- chmod 600 /opt/open-intelligent-ui/.env
msg_ok ".env geschrieben (Modell: $MODEL)."

msg_info "Baue App im Container (npm ci + build, dauert Minuten) ..."
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  cd /opt/open-intelligent-ui
  if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; else npm install --no-audit --no-fund; fi
  npm run build
  chown -R oiu:oiu /opt/open-intelligent-ui
'
msg_ok "Build ok."

# Host-seitiger Guard: bricht laut ab, falls der Build fehlt.
pct exec "$CT_ID" -- test -d /opt/open-intelligent-ui/.next \
  || { msg_error "Build unvollständig: /opt/open-intelligent-ui/.next fehlt im Container."; exit 1; }

# systemd-Unit aus diesem Repo übernehmen (fällt auf Inline-Unit zurück)
if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/open-intelligent-ui.service "$SERVICE_URL" 2>/dev/null; then
  msg_ok "open-intelligent-ui.service aus Repo übernommen."
else
  msg_warn "Service-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/open-intelligent-ui.service <<UNIT
[Unit]
Description=open-intelligent-ui – OpenUI Intelligent-UI-Demo (Next.js)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=oiu
Group=oiu
WorkingDirectory=/opt/open-intelligent-ui
EnvironmentFile=/opt/open-intelligent-ui/.env
Environment=PORT=3000
Environment=NODE_ENV=production
ExecStart=/usr/bin/node /opt/open-intelligent-ui/node_modules/next/dist/bin/next start -p 3000 -H 0.0.0.0
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
fi
pct exec "$CT_ID" -- systemctl daemon-reload
pct exec "$CT_ID" -- systemctl enable --now open-intelligent-ui

# ---------------------------------------------------------------------------
# 5. Verifikation: Service + Web UI
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
pct exec "$CT_ID" -- systemctl is-active open-intelligent-ui || { msg_error "systemd-Service open-intelligent-ui ist nicht active."; pct exec "$CT_ID" -- systemctl status open-intelligent-ui --no-pager || true; exit 1; }
msg_ok "Service läuft (systemctl is-active open-intelligent-ui = active)."

msg_info "Warte auf Web UI (max. 3 Min) ..."
WEB_OK=0
for _ in $(seq 1 18); do
  if pct exec "$CT_ID" -- curl -fs -m 10 "http://localhost:${APP_PORT}/" -o /dev/null 2>&1; then WEB_OK=1; break; fi
  sleep 10
done
[[ "$WEB_OK" == "1" ]] \
  || { msg_error "Web UI antwortet nicht auf localhost:${APP_PORT}/."; pct exec "$CT_ID" -- systemctl status open-intelligent-ui --no-pager || true; pct exec "$CT_ID" -- journalctl -u open-intelligent-ui --no-pager -n 100 || true; exit 1; }
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${APP_PORT}/)."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : open-intelligent-ui – Open-Source Intelligent UI (Next.js)"
echo "  Upstream     : $UPSTREAM_REPO"
echo "  Container    : CT $CT_ID (Hostname: $HOSTNAME_ARG, unprivilegiert, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${CT_IP}:${APP_PORT}  (Modell-Dropdown oben rechts)"
echo "  Standardmodell: $MODEL (per Dropdown zur Laufzeit wechselbar, alle OpenRouter-Modelle via /api/models)"
echo "  Hinweis      : Ohne OPENROUTER_API_KEY antwortet die UI mit 500 – Key in $APP_DIR/.env nachtragen + 'systemctl restart $APP'."
echo "  Root-Passwort: ${PASSWORD_ARG:-<bestehender CT, unverändert>} (nur jetzt angezeigt!)"
echo "  Service      : systemctl status $APP  (im Container via: pct enter $CT_ID)"
echo "  Modellwechsel: Dropdown in der Web UI – oder: pct exec $CT_ID -- nano $APP_DIR/.env (LLM_MODEL) && pct exec $CT_ID -- systemctl restart $APP"
echo "  Update       : Skript erneut laufen lassen (idempotent, --ctid $CT_ID)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Reboot-Test  : pct reboot $CT_ID && sleep 60 && curl -fs http://${CT_IP}:${APP_PORT}/ -o /dev/null && echo WEB_UI_OK"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
