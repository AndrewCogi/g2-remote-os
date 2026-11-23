#!/usr/bin/env bash
set -euo pipefail

# One-command installer for DGX Spark ARM64 (spark01: 100.101.25.64 / spark02: 100.101.25.65).
# Installs native liblc3-1 (apt), PyTorch CUDA 13.0 (Blackwell GB10 GPU), Whisper large-v3-turbo,
# FastAPI bridge, and systemd --user 24/7 service.

BRIDGE_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="${BRIDGE_DIR}/.venv"
PORT="${G2_BRIDGE_PORT:-8765}"

echo "=== 1. Ensuring native Google liblc3 shared library (ARM64 compatible) ==="
if ! ldconfig -p 2>/dev/null | grep -q "liblc3\.so"; then
  echo "Installing liblc3-1 via apt..."
  sudo apt-get update -qq || true
  sudo apt-get install -y liblc3-1 || sudo apt-get install -y liblc3-dev || true
fi

echo "=== 2. Creating/Updating Python venv at ${VENV_DIR} ==="
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --upgrade pip wheel

echo "=== 3. Ensuring PyTorch CUDA 13.0 (Blackwell GB10 GPU) ==="
if ! "${VENV_DIR}/bin/python" -c "import torch; assert torch.cuda.is_available()" 2>/dev/null; then
  "${VENV_DIR}/bin/pip" install --upgrade torch --index-url https://download.pytorch.org/whl/cu130 \
    || "${VENV_DIR}/bin/pip" install --upgrade torch --index-url https://download.pytorch.org/whl/cu128
fi

echo "=== 4. Installing Bridge & Whisper dependencies ==="
"${VENV_DIR}/bin/pip" install -r "${BRIDGE_DIR}/requirements.txt"

echo "=== 5. Checking agy CLI, Blackwell CUDA GPU & liblc3 ==="
AGY_BIN="$(command -v agy || echo "${HOME}/.local/bin/agy")"
echo "agy path: ${AGY_BIN}"
PYTHONPATH="${BRIDGE_DIR}" "${VENV_DIR}/bin/python" - <<'PY'
import torch
print("PyTorch version:", torch.__version__)
print("PyTorch CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU device:", torch.cuda.get_device_name(0), "bf16:", torch.cuda.is_bf16_supported())
from audio_decoder import G2AudioDecoder, load_liblc3
lib = load_liblc3()
print("Native liblc3 loaded:", lib)
if lib is not None:
    dec = G2AudioDecoder("lc3_16k")
    pcm = dec.decode(bytes(40))
    print("Test LC3 decode samples:", len(pcm), pcm.dtype)
PY

echo "=== 6. Installing/Restarting systemd --user service (g2-spark-bridge.service) ==="
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
Environment="G2_STT_BACKEND=auto"
Environment="G2_DEFAULT_EFFORT=low"
ExecStart=${VENV_DIR}/bin/uvicorn server:app --host 0.0.0.0 --port ${PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable g2-spark-bridge.service
systemctl --user restart g2-spark-bridge.service
loginctl enable-linger "${USER}" 2>/dev/null || true

echo "=== 7. Done! Checking status ==="
sleep 2
systemctl --user status g2-spark-bridge.service --no-pager || true
echo ""
echo "Health check (after first-time GPU model load): curl -s http://127.0.0.1:${PORT}/health"
