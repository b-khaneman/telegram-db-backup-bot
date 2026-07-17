#!/usr/bin/env bash
# Reload service after .env or code changes (Ubuntu)
set -euo pipefail
SERVICE_NAME="${SERVICE_NAME:-backup-bot}"
sudo systemctl daemon-reload
sudo systemctl restart "${SERVICE_NAME}"
sudo systemctl --no-pager --full status "${SERVICE_NAME}"
