#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="$HOME/.config/hypr/conf/monitors/generated/state.env"

# fallback
[[ -f "$STATE_FILE" ]] || STATE_FILE="$HOME/.config/hypr/conf/monitors/state.env"

# =========================
# LOAD STATE
# =========================
LAST_LAYOUT="line-left"
WS_PER_MONITOR="5"
FORCED_PRIMARY_NAME=""
FORCED_PRIMARY_SERIAL=""

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi

# =========================
# MONITORS
# =========================
MONITORS_JSON="$(hyprctl monitors -j 2>/dev/null || echo '[]')"

# =========================
# WORKSPACES REALI
# =========================
sleep 0.1
WORKSPACES_JSON="$(hyprctl workspaces -j 2>/dev/null || echo '[]')"

TOTAL_WS=$(echo "$WORKSPACES_JSON" | jq 'length')
MONITOR_COUNT=$(echo "$MONITORS_JSON" | jq '[.[] | select(.width>0)] | length')

if [[ "$MONITOR_COUNT" -gt 0 && "$TOTAL_WS" -gt 0 ]]; then
  WS_REAL=$((TOTAL_WS / MONITOR_COUNT))
else
  WS_REAL="$WS_PER_MONITOR"
fi

# =========================
# MONITOR LIST
# =========================
MONITORS_LIST=$(echo "$MONITORS_JSON" | jq -c '
  [
    .[]
    | select(.name != null)
    | select(.width > 0)
    | {
        name: .name,
        serial: (.serial // ""),
        width: (.width // 0),
        height: (.height // 0)
      }
  ]
')

# =========================
# PRIMARY
# =========================
PRIMARY_MODE="auto"
PRIMARY_VALUE=""
CURRENT_PRIMARY=""

if [[ -n "${FORCED_PRIMARY_SERIAL:-}" ]]; then
  PRIMARY_MODE="serial"
  PRIMARY_VALUE="$FORCED_PRIMARY_SERIAL"

  CURRENT_PRIMARY=$(echo "$MONITORS_JSON" | jq -r \
    ".[] | select(.serial==\"$FORCED_PRIMARY_SERIAL\") | .name" | head -n1)

elif [[ -n "${FORCED_PRIMARY_NAME:-}" ]]; then
  PRIMARY_MODE="name"
  PRIMARY_VALUE="$FORCED_PRIMARY_NAME"
  CURRENT_PRIMARY="$FORCED_PRIMARY_NAME"

else
  CURRENT_PRIMARY=$(echo "$MONITORS_JSON" | jq -r '
    .[]
    | select(.focused == true)
    | .name
  ' | head -n1)

  [[ -z "$CURRENT_PRIMARY" ]] && CURRENT_PRIMARY=$(echo "$MONITORS_JSON" | jq -r '.[0].name // ""')
fi

# =========================
# OUTPUT JSON
# =========================
jq -n \
  --arg layout "$LAST_LAYOUT" \
  --arg ws "$WS_REAL" \
  --arg pmode "$PRIMARY_MODE" \
  --arg pvalue "$PRIMARY_VALUE" \
  --arg pcurrent "$CURRENT_PRIMARY" \
  --argjson monitors "$MONITORS_LIST" \
  '
{
  layout: { value: $layout, source: "runtime" },
  workspaces: { value: ($ws|tonumber), source: "runtime" },
  primary: {
    mode: $pmode,
    value: $pvalue,
    currentName: $pcurrent
  },
  preferredSerial: "",
  layouts: ["line-left","line-right","line-top","line-bottom","split-lr","split-tb"],
  monitors: $monitors
}
'