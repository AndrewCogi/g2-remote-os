#!/usr/bin/env bash
set -euo pipefail

# One-command installer for DGX Spark (spark01: 100.101.25.64 / spark02: 100.101.25.65).
# Installs Python venv, faster-whisper (CUDA), lc3py, FastAPI bridge, and a 24/7 systemd user service.

BRIDGE_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="${BRIDGE_DIR}/.venv"
PORT="${G2_BRIDGE_PORT:-8765}"

echo "=== 1. Creating Python venv at ${VENV_DIR} ==="
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --upgrade pip wheel
"${VENV_DIR}/bin/pip" install -r "${BRIDGE_DIR}/requirements.txt"

echo "=== 2. Checking agy CLI & CUDA GPU ==="
AGY_BIN="$(command -v agy || echo "${HOME}/.local/bin/agy")"
echo "agy path: ${AGY_BIN}"
"${VENV_DIR}/bin/python" - <<'PY'
import ctranslate2
print("CUDA devices visible to faster-whisper:", ctranslate2.get_cuda_device_count())
import lc3
print("lc3py import OK:", lc3)
PY

echo "=== 3. Installing systemd --user service (g2-spark-bridge.service) ==="
mkdir -p "${HOME}/.config/systemd/user"
cat > "${HOME}/.config/systemd/user/g2-spark-bridge.service" <<EOF
[Unit]
Description=G2 OS DGX Spark Real-Time Voice & AGY Bridge
After=network-online.target tailscaled.service

[Service]
Type=simple
WorkingDirectory=${BRIDGE_DIR}
Environment="PATH=${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"
Environment="G2_AGY_BIN=${AGY_BIN}"
Environment="G2_WHISPER_MODEL=large-v3-turbo"
Environment="G2_DEFAULT_EFFORT=low"
ExecStart=${VENV_DIR}/bin/uvicorn server:app --host 0.0.0.0 --port ${PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now g2-spark-bridge.service
loginctl enable-linger "${USER}" 2>/dev/null || true

echo "=== 4. Done! Checking status ==="
sleep 2
systemctl --user status g2-spark-bridge.service --no-pager || true
echo ""
echo "Health check: curl http://127.0.0.1:${PORT}/health"
