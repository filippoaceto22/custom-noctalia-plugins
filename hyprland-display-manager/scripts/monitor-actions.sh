#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPT_DIR/monitor-engine.sh"

case "${1:-}" in
  apply)
    "$ENGINE" apply "${2:-}"
    ;;

  set-primary)
    "$ENGINE" set-primary "${2:-}"
    ;;

  set-primary-serial)
    "$ENGINE" set-primary-serial "${2:-}"
    ;;

  clear-primary-serial)
    "$ENGINE" clear-primary-serial
    ;;

  clear-primary)
    "$ENGINE" clear-primary
    ;; 

  set-ws-per-monitor)
    "$ENGINE" set-ws-per-monitor "${2:-}"
    ;;

  *)
    echo "Usage:"
    echo "  apply <layout>"
    echo "  set-primary <name>"
    echo "  set-primary-serial <serial>"
    echo "  clear-primary-serial"
    echo "  clear-primary"
    echo "  set-ws-per-monitor <n>"
    exit 1
    ;;
esac