#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# monitor-autogen.sh
# - Generates monitor profiles for Hyprland (multi-monitor layouts)
# - Persists runtime choices (primary + ws-per-monitor override) into state.env
# - Listens to monitor add/remove events, and survives logout/login by reattaching
# - Optional: after events, resets "workspace view" and recenters floating windows
# ============================================================

CMD="${1:-listen}"
shift || true

# Settings file (can be overridden via env)
SETTINGS_FILE="${SETTINGS_FILE:-$HOME/.config/hypr/conf/monitors/settings.env}"

# ---- defaults (override in settings.env) ----
WS_PER_MONITOR="${WS_PER_MONITOR:-6}"
DEFAULT_LAYOUT="${DEFAULT_LAYOUT:-line-left}"
PRIMARY_DEFAULT_NAME="${PRIMARY_DEFAULT_NAME:-HDMI-A-1}"
PRIMARY_PREFER_REGEX="${PRIMARY_PREFER_REGEX:-^(HDMI|DP)}"
USE_PREFERRED_MODE="${USE_PREFERRED_MODE:-0}"
GENERATE_PRIMARY_ROTATION="${GENERATE_PRIMARY_ROTATION:-1}"

# ---- stable identification + class-based overrides ----
PRIMARY_PREFER_SERIAL="${PRIMARY_PREFER_SERIAL:-}"         # preferred serial in settings.env
FORCED_PRIMARY_SERIAL="${FORCED_PRIMARY_SERIAL:-}"         # runtime forced serial in state.env
FORCED_PRIMARY_NAME="${FORCED_PRIMARY_NAME:-}"             # runtime forced name in state.env (legacy)

INTERNAL_PANEL_MODE="${INTERNAL_PANEL_MODE:-preferred}"
INTERNAL_PANEL_SCALE="${INTERNAL_PANEL_SCALE:-1.0}"

EXTERNAL_DEFAULT_MODE="${EXTERNAL_DEFAULT_MODE:-preferred}"
EXTERNAL_DEFAULT_SCALE="${EXTERNAL_DEFAULT_SCALE:-}"       # empty => use scale read from hyprctl

# Output / state
OUT_DIR="${OUT_DIR:-$HOME/.config/hypr/conf/monitors/generated}"
CURRENT_FILE="${CURRENT_FILE:-$OUT_DIR/current.conf}"

STATE_FILE="${STATE_FILE:-$OUT_DIR/state.env}"
LAST_SIG_FILE="${LAST_SIG_FILE:-$OUT_DIR/last_sig}"
CLEAN_OUT_DIR="${CLEAN_OUT_DIR:-1}"

# Remap windows if workspace range decreases
REMAP_EXTRA_WINDOWS="${REMAP_EXTRA_WINDOWS:-1}"
REMAP_MODE="${REMAP_MODE:-shift}"          # shift | modulo
REMAP_SILENT="${REMAP_SILENT:-1}"
REMAP_DELAY_SEC="${REMAP_DELAY_SEC:-0.15}"

# Waybar restart
POST_EVENT_CMD="${POST_EVENT_CMD:-$HOME/.config/waybar/launch.sh}"
POST_EVENT_DELAY_SEC="${POST_EVENT_DELAY_SEC:-0.20}"
FORCE_RESTART_WAYBAR_ON_EVENT="${FORCE_RESTART_WAYBAR_ON_EVENT:-1}"

# Event stabilization
DEBOUNCE_SEC="${DEBOUNCE_SEC:-0.35}"
RECONCILE_WINDOW_SEC="${RECONCILE_WINDOW_SEC:-6}"
RECONCILE_STEP_SEC="${RECONCILE_STEP_SEC:-0.35}"
POLL_SEC="${POLL_SEC:-2.5}"

FOCUS_OUT_OF_RANGE_TARGET="${FOCUS_OUT_OF_RANGE_TARGET:-last}"

# Reset “workspace view” after event/startup/UI commands:
# primary -> ws 1 ; monitor i-th -> ((i-1)*WS_PER_MONITOR + 1)
RESET_WS_VIEW_ON_EVENT="${RESET_WS_VIEW_ON_EVENT:-1}"
RESET_WS_VIEW_DELAY_SEC="${RESET_WS_VIEW_DELAY_SEC:-0.15}"
EVENT_CONTEXT="${EVENT_CONTEXT:-0}"  # 1 when triggered by event/startup/UI commands

# Floating windows: if off-screen after changes, move them to the "correct" monitor
RECENTER_FLOATING_ON_EVENT="${RECENTER_FLOATING_ON_EVENT:-1}"
RECENTER_FLOATING_ONLY_IF_OFFSCREEN="${RECENTER_FLOATING_ONLY_IF_OFFSCREEN:-1}"
RECENTER_FLOATING_DELAY_SEC="${RECENTER_FLOATING_DELAY_SEC:-0.20}"
RECENTER_FLOATING_OOB_MARGIN="${RECENTER_FLOATING_OOB_MARGIN:-10}"

# Logging
LOG_FILE="${LOG_FILE:-/tmp/monitor-autogen.log}"
DEBUG="${DEBUG:-0}"

ts(){ date "+%Y-%m-%d %H:%M:%S"; }
log(){
  local msg="[$(ts)] $*"
  echo "$msg" >> "$LOG_FILE"
  [[ "$DEBUG" == "1" ]] && echo "$msg" >&2 || true
}

require_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }

# ============================================================
# Hyprland session resolution (fixes logout/login + AGS calls)
# ============================================================

resolve_hypr_sig() {
  # Ensure XDG_RUNTIME_DIR exists
  if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
  fi

  local base="${XDG_RUNTIME_DIR}/hypr"
  [[ -d "$base" ]] || { echo ""; return 0; }

  # If current signature is valid, keep it
  if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && [[ -S "$base/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" ]]; then
    echo "$HYPRLAND_INSTANCE_SIGNATURE"
    return 0
  fi

  # Otherwise pick the most recently touched socket2.sock
  local best=""
  for d in "$base"/*; do
    [[ -d "$d" && -S "$d/.socket2.sock" ]] || continue
    if [[ -z "$best" ]]; then
      best="$(basename "$d")"
    else
      if [[ "$d/.socket2.sock" -nt "$base/$best/.socket2.sock" ]]; then
        best="$(basename "$d")"
      fi
    fi
  done

  echo "$best"
}

ensure_hypr_env() {
  local sig
  sig="$(resolve_hypr_sig)"
  [[ -n "$sig" ]] || return 1
  export HYPRLAND_INSTANCE_SIGNATURE="$sig"
  return 0
}

# ============================================================
# State/settings
# ============================================================

load_settings(){
  if [[ -f "$SETTINGS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SETTINGS_FILE"
  fi
  mkdir -p "$OUT_DIR"
}

load_state(){
  if [[ -f "$STATE_FILE" ]]; then
    set +e
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    local rc=$?
    set -e
    if (( rc != 0 )); then
      log "state.env non valido, lo sposto: rc=$rc"
      mv -f "$STATE_FILE" "$STATE_FILE.bad.$(date +%s)" || true
    fi
  fi

  LAST_LAYOUT="${LAST_LAYOUT:-$DEFAULT_LAYOUT}"
  LAST_PRIMARY_NAME="${LAST_PRIMARY_NAME:-}"
  FORCED_PRIMARY_NAME="${FORCED_PRIMARY_NAME:-}"
  FORCED_PRIMARY_SERIAL="${FORCED_PRIMARY_SERIAL:-}"
  LAST_MONITOR_COUNT="${LAST_MONITOR_COUNT:-0}"
  LAST_WS_PER_MONITOR="${LAST_WS_PER_MONITOR:-0}"
  WS_PER_MONITOR_OVERRIDE="${WS_PER_MONITOR_OVERRIDE:-}"
}

save_state(){
  mkdir -p "$(dirname "$STATE_FILE")"
  {
    printf "LAST_LAYOUT=%q\n" "$LAST_LAYOUT"
    printf "LAST_PRIMARY_NAME=%q\n" "$LAST_PRIMARY_NAME"
    printf "FORCED_PRIMARY_NAME=%q\n" "$FORCED_PRIMARY_NAME"
    printf "FORCED_PRIMARY_SERIAL=%q\n" "$FORCED_PRIMARY_SERIAL"
    printf "LAST_MONITOR_COUNT=%q\n" "$LAST_MONITOR_COUNT"
    printf "LAST_WS_PER_MONITOR=%q\n" "$LAST_WS_PER_MONITOR"
    printf "WS_PER_MONITOR_OVERRIDE=%q\n" "$WS_PER_MONITOR_OVERRIDE"
  } > "$STATE_FILE"
}

apply_runtime_overrides(){
  if [[ -n "${WS_PER_MONITOR_OVERRIDE:-}" ]]; then
    WS_PER_MONITOR="$WS_PER_MONITOR_OVERRIDE"
  fi
}

get_last_sig(){ [[ -f "$LAST_SIG_FILE" ]] && cat "$LAST_SIG_FILE" || true; }
set_last_sig(){ printf "%s" "$1" > "$LAST_SIG_FILE"; }

sanitize(){ local s="$1"; s="${s,,}"; s="${s//[^a-z0-9]/-}"; echo "$s"; }

clean_generated_dir(){
  [[ "$CLEAN_OUT_DIR" == "1" ]] || return 0
  find "$OUT_DIR" -maxdepth 1 -type f -name '*.conf' -delete 2>/dev/null || true
  rm -f "$CURRENT_FILE" 2>/dev/null || true
}

# ============================================================
# hyprctl helpers
# ============================================================

declare -A MW MH MSCALE MRR MTRANS MMAKE MMODEL MSERIAL
reset_props(){ MW=(); MH=(); MSCALE=(); MRR=(); MTRANS=(); MMAKE=(); MMODEL=(); MSERIAL=(); }

get_monitors_json(){
  ensure_hypr_env || { log "no hypr session found (get_monitors_json)"; echo "[]"; return 0; }
  hyprctl monitors -j 2>/dev/null || echo "[]"
}

# enabled monitor = disabled!=true AND width/height > 0
get_monitor_names(){
  local json="$1"
  echo "$json" | jq -r '
    sort_by(.id)[]
    | select((.name // "") != "")
    | select((.disabled // false) == false)
    | select((.width // 0) > 0 and (.height // 0) > 0)
    | .name
  ' | awk 'NF>0'
}

monitors_key(){
  local json="$1"
  echo "$json" | jq -r '
    [ .[]
      | select((.name // "") != "")
      | select((.disabled // false) == false)
      | select((.width // 0) > 0 and (.height // 0) > 0)
      | .name
    ] | sort | join(",")
  '
}

# Stabilize monitor list: return a JSON that repeats key twice in a row
get_stable_monitors_json(){
  local last="" same=0 json="" key=""
  for _ in $(seq 1 30); do
    json="$(get_monitors_json)"
    key="$(monitors_key "$json")"
    if [[ -n "$key" && "$key" == "$last" ]]; then
      same=$((same+1))
      if (( same >= 2 )); then
        echo "$json"
        return 0
      fi
    else
      same=0
      last="$key"
    fi
    sleep 0.12
  done
  echo "${json:-[]}"
}

fill_monitor_props(){
  local json="$1"; reset_props
  while IFS=$'\t' read -r name w h scale rr trans make model serial; do
    [[ -n "${name:-}" ]] || continue
    MW["$name"]="${w:-0}"; MH["$name"]="${h:-0}"
    MSCALE["$name"]="${scale:-1}"; MRR["$name"]="${rr:-0}"
    MTRANS["$name"]="${trans:-0}"
    MMAKE["$name"]="${make:-}"
    MMODEL["$name"]="${model:-}"
    MSERIAL["$name"]="${serial:-}"
  done < <(
    echo "$json" | jq -r '
      sort_by(.id)[]
      | select((.name // "") != "")
      | select((.disabled // false) == false)
      | select((.width // 0) > 0 and (.height // 0) > 0)
      | [
          .name,
          (.width|tostring),
          (.height|tostring),
          ((.scale//1)|tostring),
          ((.refreshRate//0)|tostring),
          ((.transform//0)|tostring),
          (.make // ""),
          (.model // ""),
          (.serial // "")
        ]
      | @tsv'
  )
}

get_w(){ echo "${MW[$1]-0}"; }
get_h(){ echo "${MH[$1]-0}"; }
get_s(){ echo "${MSCALE[$1]-1}"; }
get_rr(){ echo "${MRR[$1]-0}"; }
get_t(){ echo "${MTRANS[$1]-0}"; }
get_serial(){ echo "${MSERIAL[$1]-}"; }

is_internal_panel(){ [[ "$1" =~ ^(eDP|LVDS)- ]]; }
is_external_port(){ [[ "$1" =~ ^(HDMI|DP)- ]]; }

mode_for() {
  local name="$1"

  # class: internal
  if is_internal_panel "$name" && [[ -n "${INTERNAL_PANEL_MODE:-}" ]]; then
    echo "$INTERNAL_PANEL_MODE"; return 0
  fi

  # per-name override
  local key="MONITOR_MODE_${name//[^A-Za-z0-9]/_}"
  local override="${!key-}"
  if [[ -n "$override" ]]; then echo "$override"; return 0; fi

  # class: external
  if is_external_port "$name" && [[ -n "${EXTERNAL_DEFAULT_MODE:-}" ]]; then
    echo "$EXTERNAL_DEFAULT_MODE"; return 0
  fi

  # legacy: always preferred
  if [[ "$USE_PREFERRED_MODE" == "1" ]]; then
    echo "preferred"; return 0
  fi

  # build WxH@RR if possible
  local w h rr
  w="$(get_w "$name")"; h="$(get_h "$name")"; rr="$(get_rr "$name")"
  if [[ -z "$w" || "$w" == "0" || -z "$h" || "$h" == "0" ]]; then
    echo "preferred"; return 0
  fi
  if [[ -z "$rr" || "$rr" == "0" || "$rr" == "0.0" ]]; then
    echo "${w}x${h}"
  else
    echo "${w}x${h}@${rr}"
  fi
}

scale_for() {
  local name="$1"

  # class: internal
  if is_internal_panel "$name" && [[ -n "${INTERNAL_PANEL_SCALE:-}" ]]; then
    echo "$INTERNAL_PANEL_SCALE"; return 0
  fi

  # per-name override
  local key="MONITOR_SCALE_${name//[^A-Za-z0-9]/_}"
  local override="${!key-}"
  if [[ -n "$override" ]]; then echo "$override"; return 0; fi

  # class: external
  if is_external_port "$name" && [[ -n "${EXTERNAL_DEFAULT_SCALE:-}" ]]; then
    echo "$EXTERNAL_DEFAULT_SCALE"; return 0
  fi

  echo "$(get_s "$name")"
}

# "logical" size used for layout computations (tries to keep alignment with scale)
logical_w(){ awk -v w="$(get_w "$1")" -v s="$(get_s "$1")" 'BEGIN{if(s==0)s=1; printf "%.0f", (w/s)}'; }
logical_h(){ awk -v h="$(get_h "$1")" -v s="$(get_s "$1")" 'BEGIN{if(s==0)s=1; printf "%.0f", (h/s)}'; }
logical_w_swapped(){ local t; t="$(get_t "$1")"; [[ "$t" =~ ^(1|3|5|7)$ ]] && logical_h "$1" || logical_w "$1"; }
logical_h_swapped(){ local t; t="$(get_t "$1")"; [[ "$t" =~ ^(1|3|5|7)$ ]] && logical_w "$1" || logical_h "$1"; }

choose_primary(){
  local -a names=("$@")

  # 1) forced serial
  if [[ -n "${FORCED_PRIMARY_SERIAL:-}" ]]; then
    for n in "${names[@]}"; do
      [[ "$(get_serial "$n")" == "$FORCED_PRIMARY_SERIAL" ]] && { echo "$n"; return; }
    done
  fi

  # 2) forced name (legacy)
  if [[ -n "${FORCED_PRIMARY_NAME:-}" ]]; then
    for n in "${names[@]}"; do [[ "$n" == "$FORCED_PRIMARY_NAME" ]] && { echo "$n"; return; }; done
  fi

  # 3) preferred serial from settings
  if [[ -n "${PRIMARY_PREFER_SERIAL:-}" ]]; then
    for n in "${names[@]}"; do
      [[ "$(get_serial "$n")" == "$PRIMARY_PREFER_SERIAL" ]] && { echo "$n"; return; }
    done
  fi

  # 4) default name
  for n in "${names[@]}"; do [[ "$n" == "$PRIMARY_DEFAULT_NAME" ]] && { echo "$n"; return; }; done

  # 5) last primary
  if [[ -n "${LAST_PRIMARY_NAME:-}" ]]; then
    for n in "${names[@]}"; do [[ "$n" == "$LAST_PRIMARY_NAME" ]] && { echo "$n"; return; }; done
  fi

  # 6) prefer by regex
  for n in "${names[@]}"; do [[ "$n" =~ $PRIMARY_PREFER_REGEX ]] && { echo "$n"; return; }; done

  # 7) any external
  for n in "${names[@]}"; do is_external_port "$n" && { echo "$n"; return; }; done

  echo "${names[0]}"
}

order_secondaries(){
  local primary="$1"; shift
  local -a names=("$@") out=()
  for n in "${names[@]}"; do [[ -n "$n" && "$n" != "$primary" ]] && out+=("$n"); done
  printf '%s\n' "${out[@]}"
}

layouts_list(){ echo "line-right line-left line-top line-bottom split-lr split-tb"; }

compute_positions(){
  local primary="$1" layout="$2"; shift 2
  local -a secs=("$@")
  local pW pH; pW="$(logical_w_swapped "$primary")"; pH="$(logical_h_swapped "$primary")"
  case "$layout" in
    line-right) local x="$pW" y=0; for m in "${secs[@]}"; do echo -e "$m\t$x\t$y"; x=$((x+$(logical_w_swapped "$m"))); done;;
    line-left)  local x=0 y=0; for m in "${secs[@]}"; do x=$((x-$(logical_w_swapped "$m"))); echo -e "$m\t$x\t$y"; done;;
    line-bottom)local x=0 y="$pH"; for m in "${secs[@]}"; do echo -e "$m\t$x\t$y"; y=$((y+$(logical_h_swapped "$m"))); done;;
    line-top)   local x=0 y=0; for m in "${secs[@]}"; do y=$((y-$(logical_h_swapped "$m"))); echo -e "$m\t$x\t$y"; done;;
    split-lr)
      local right_x="$pW" left_x=0 y=0 i=0
      for m in "${secs[@]}"; do local mw; mw="$(logical_w_swapped "$m")"
        if (( i%2==0 )); then echo -e "$m\t$right_x\t$y"; right_x=$((right_x+mw))
        else left_x=$((left_x-mw)); echo -e "$m\t$left_x\t$y"; fi
        i=$((i+1))
      done;;
    split-tb)
      local bottom_y="$pH" top_y=0 x=0 i=0
      for m in "${secs[@]}"; do local mh; mh="$(logical_h_swapped "$m")"
        if (( i%2==0 )); then echo -e "$m\t$x\t$bottom_y"; bottom_y=$((bottom_y+mh))
        else top_y=$((top_y-mh)); echo -e "$m\t$x\t$top_y"; fi
        i=$((i+1))
      done;;
    *) return 1;;
  esac
}

# ============================================================
# Workspace helpers
# ============================================================

force_active_ws_in_range(){
  local monitor_count="${1:-1}"
  local ws_per="${2:-1}"
  [[ "$monitor_count" =~ ^[0-9]+$ ]] || monitor_count=1
  [[ "$ws_per" =~ ^[0-9]+$ ]] || ws_per=1
  local max=$(( monitor_count * ws_per ))
  (( max >= 1 )) || max=1

  local cur
  cur="$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // 1' || echo 1)"
  [[ "$cur" =~ ^[0-9]+$ ]] || cur=1

  if (( cur > max )); then
    log "active ws $cur > max $max -> force focus"
    if [[ "$FOCUS_OUT_OF_RANGE_TARGET" == "first" ]]; then
      hyprctl dispatch workspace 1 >/dev/null 2>&1 || true
    else
      hyprctl dispatch workspace "$max" >/dev/null 2>&1 || true
    fi
  fi
}

reset_ws_view_all_monitors() {
  local -a mons=("$@")
  ((${#mons[@]}>=1)) || return 0

  local batch=""
  local i=0
  for m in "${mons[@]}"; do
    i=$((i+1))
    local ws=$(( (i-1)*WS_PER_MONITOR + 1 ))
    batch+="dispatch workspace ${ws}; "
  done

  hyprctl --batch "$batch" >/dev/null 2>&1 || true
}
# ============================================================
# Floating windows: move only if truly off-screen
# - Target monitor is derived from workspace block (ws-per-monitor mapping)
# ============================================================

recenter_floating_windows_if_offscreen() {
  [[ "${RECENTER_FLOATING_ON_EVENT:-1}" == "1" ]] || return 0

  local -a mons=("$@")
  ((${#mons[@]}>=1)) || return 0

  local mons_json clients_json
  mons_json="$(hyprctl monitors -j 2>/dev/null || echo '[]')"
  clients_json="$(hyprctl clients -j 2>/dev/null || echo '[]')"

  local max_ws=$(( ${#mons[@]} * WS_PER_MONITOR ))
  (( max_ws >= 1 )) || return 0

  # Select floating windows (not special workspaces), optionally only those NOT intersecting ANY monitor rect.
  local clients_tsv
  if [[ "${RECENTER_FLOATING_ONLY_IF_OFFSCREEN:-1}" == "1" ]]; then
    clients_tsv="$(
      echo "$clients_json" | jq -r --argjson mons "$mons_json" '
        .[]
        | select(.floating==true)
        | select(.pinned != true)
        | select((.workspace.name|tostring) | startswith("special:") | not)
        | select(.address != null and .workspace != null and (.workspace.id|type=="number"))
        | select(.at != null and .size != null)
        | . as $c
        | ($mons | any(. as $m
            | ($c.at[0] + $c.size[0] > ($m.x//0))
            and ($c.at[0] < (($m.x//0) + ($m.width//0)))
            and ($c.at[1] + $c.size[1] > ($m.y//0))
            and ($c.at[1] < (($m.y//0) + ($m.height//0)))
          )) as $visible
        | select($visible | not)
        | [
            $c.address,
            ($c.workspace.id|tostring),
            ($c.size[0]|tostring),
            ($c.size[1]|tostring)
          ] | @tsv
      ' 2>/dev/null || true
    )"
  else
    clients_tsv="$(
      echo "$clients_json" | jq -r '
        .[]
        | select(.floating==true)
        | select(.pinned != true)
        | select((.workspace.name|tostring) | startswith("special:") | not)
        | select(.address != null and .workspace != null and (.workspace.id|type=="number"))
        | select(.size != null)
        | [
            .address,
            (.workspace.id|tostring),
            (.size[0]|tostring),
            (.size[1]|tostring)
          ] | @tsv
      ' 2>/dev/null || true
    )"
  fi

  [[ -n "${clients_tsv:-}" ]] || return 0

  local margin="${RECENTER_FLOATING_OOB_MARGIN:-10}"
  local batch=""

  # helper to read monitor rect by name from mons_json
  get_rect() {
    local m="$1"
    echo "$mons_json" | jq -r --arg m "$m" '
      .[] | select(.name==$m)
      | "\(.x//0)\t\(.y//0)\t\(.width//0)\t\(.height//0)"
    ' | head -n1
  }

  while IFS=$'\t' read -r addr ws ww wh; do
    [[ -n "${addr:-}" ]] || continue
    [[ "$ws" =~ ^[0-9]+$ ]] || continue
    [[ "$ww" =~ ^[0-9]+$ && "$wh" =~ ^[0-9]+$ ]] || continue
    (( ws >= 1 && ws <= max_ws )) || continue

    # map workspace -> monitor index
    local idx=$(( (ws - 1) / WS_PER_MONITOR ))
    (( idx < 0 )) && idx=0
    (( idx >= ${#mons[@]} )) && idx=$(( ${#mons[@]} - 1 ))
    local target="${mons[$idx]}"

    local rect
    rect="$(get_rect "$target")"
    [[ -n "$rect" ]] || continue

    local mx my mw mh
    mx="$(echo "$rect" | awk '{print $1}')"
    my="$(echo "$rect" | awk '{print $2}')"
    mw="$(echo "$rect" | awk '{print $3}')"
    mh="$(echo "$rect" | awk '{print $4}')"

    [[ "$mx" =~ ^-?[0-9]+$ && "$my" =~ ^-?[0-9]+$ && "$mw" =~ ^[0-9]+$ && "$mh" =~ ^[0-9]+$ ]] || continue
    (( mw > 0 && mh > 0 )) || continue

    # center + clamp within target rect
    local minX=$(( mx + margin ))
    local minY=$(( my + margin ))
    local maxX=$(( mx + mw - ww - margin ))
    local maxY=$(( my + mh - wh - margin ))

    local nx=$(( mx + (mw - ww)/2 ))
    local ny=$(( my + (mh - wh)/2 ))

    if (( maxX < minX )); then nx=$minX; else
      (( nx < minX )) && nx=$minX
      (( nx > maxX )) && nx=$maxX
    fi
    if (( maxY < minY )); then ny=$minY; else
      (( ny < minY )) && ny=$minY
      (( ny > maxY )) && ny=$maxY
    fi

    batch+="dispatch movewindowpixel exact ${nx} ${ny},address:${addr};"
  done <<< "$clients_tsv"

  [[ -n "$batch" ]] || return 0
  log "recenter floating offscreen: moved windows"
  hyprctl --batch "$batch" >/dev/null 2>&1 || true
}

# ============================================================
# Profile generation
# ============================================================

write_profile_multi(){
  local primary="$1" layout="$2" outfile="$3"; shift 3
  local -a all_in=("$@") all=()
  for m in "${all_in[@]}"; do [[ -n "${m:-}" ]] && all+=("$m"); done
  local count="${#all[@]}"; ((count>=1)) || return 0

  cat > "$outfile" <<EOF
# AUTO-GENERATED by monitor-autogen.sh
# primary=$primary layout=$layout count=$count ws_per_monitor=$WS_PER_MONITOR
EOF

  local idx=1
  for m in "${all[@]}"; do echo "\$m$idx = $m" >> "$outfile"; idx=$((idx+1)); done
  echo "" >> "$outfile"
  echo "env = primario,\$m1" >> "$outfile"
  ((count>=2)) && echo "env = secondario,\$m2" >> "$outfile"
  echo "" >> "$outfile"

  echo "monitor=\$m1,$(mode_for "$primary"),0x0,$(scale_for "$primary")" >> "$outfile"

  if ((count>=2)); then
    local -a secs=("${all[@]:1}")
    local out_idx=2
    while IFS=$'\t' read -r m x y; do
      echo "monitor=\$m$out_idx,$(mode_for "$m"),${x}x${y},$(scale_for "$m")" >> "$outfile"
      out_idx=$((out_idx+1))
    done < <(compute_positions "$primary" "$layout" "${secs[@]}")
  fi

  echo "" >> "$outfile"
  echo "# Workspaces: $WS_PER_MONITOR per monitor" >> "$outfile"

  local ws=1
  for ((i=1;i<=count;i++)); do
    for ((k=0;k<WS_PER_MONITOR;k++)); do
      echo "workspace = $ws,monitor:\$m$i,persistent:true" >> "$outfile"
      ws=$((ws+1))
    done
  done
}

generate_profiles_from_json(){
  local json="$1"
  fill_monitor_props "$json"

  mapfile -t names < <(get_monitor_names "$json")
  (( ${#names[@]} >= 1 )) || return 0

  local primary; primary="$(choose_primary "${names[@]}")"
  mapfile -t secs < <(order_secondaries "$primary" "${names[@]}")
  local count_guess=$((1+${#secs[@]}))
  local -a all=("$primary" "${secs[@]}")

  for l in $(layouts_list); do
    write_profile_multi "$primary" "$l" "$OUT_DIR/multi${count_guess}-prim_$(sanitize "$primary")-${l}.conf" "${all[@]}"
  done

  if [[ "$GENERATE_PRIMARY_ROTATION" == "1" ]]; then
    for p in "${names[@]}"; do
      [[ "$p" == "$primary" ]] && continue
      mapfile -t secs2 < <(order_secondaries "$p" "${names[@]}")
      local count_guess2=$((1+${#secs2[@]}))
      local -a all2=("$p" "${secs2[@]}")
      for l in $(layouts_list); do
        write_profile_multi "$p" "$l" "$OUT_DIR/multi${count_guess2}-prim_$(sanitize "$p")-${l}.conf" "${all2[@]}"
      done
    done
  fi
}

# ============================================================
# Remap windows when range shrinks
# ============================================================

remap_modulo_to_range(){
  local new_total="$1"
  (( new_total >= 1 )) || return 0

  local clients_tsv
  clients_tsv="$(
    hyprctl clients -j 2>/dev/null | jq -r --argjson max "$new_total" '
      .[]
      | select(.address != null)
      | select(.workspace != null and .workspace.id != null and (.workspace.id|type=="number"))
      | select((.workspace.name|tostring) | startswith("special:") | not)
      | select(.workspace.id > $max)
      | [.address, (.workspace.id|tostring)] | @tsv
    ' 2>/dev/null || true
  )"
  [[ -n "$clients_tsv" ]] || return 0

  local batch=""
  while IFS=$'\t' read -r addr old_ws; do
    [[ -n "${addr:-}" && -n "${old_ws:-}" ]] || continue
    local new_ws=$(( (old_ws - 1) % new_total + 1 ))
    if [[ "$REMAP_SILENT" == "1" ]]; then
      batch+="dispatch movetoworkspacesilent ${new_ws},address:${addr};"
    else
      batch+="dispatch movetoworkspace ${new_ws},address:${addr};"
    fi
  done <<< "$clients_tsv"

  [[ -n "$batch" ]] || return 0
  hyprctl --batch "$batch" >/dev/null 2>&1 || true
}

remap_shift_to_range(){
  local new_total="$1" shift="$2"
  (( new_total >= 1 )) || return 0

  local clients_tsv
  clients_tsv="$(
    hyprctl clients -j 2>/dev/null | jq -r --argjson max "$new_total" '
      .[]
      | select(.address != null)
      | select(.workspace != null and .workspace.id != null and (.workspace.id|type=="number"))
      | select((.workspace.name|tostring) | startswith("special:") | not)
      | select(.workspace.id > $max)
      | [.address, (.workspace.id|tostring)] | @tsv
    ' 2>/dev/null || true
  )"
  [[ -n "$clients_tsv" ]] || return 0

  local batch=""
  while IFS=$'\t' read -r addr old_ws; do
    [[ -n "${addr:-}" && -n "${old_ws:-}" ]] || continue
    local new_ws=$(( old_ws - shift ))
    while (( new_ws < 1 )); do new_ws=$(( new_ws + new_total )); done
    while (( new_ws > new_total )); do new_ws=$(( new_ws - new_total )); done
    if [[ "$REMAP_SILENT" == "1" ]]; then
      batch+="dispatch movetoworkspacesilent ${new_ws},address:${addr};"
    else
      batch+="dispatch movetoworkspace ${new_ws},address:${addr};"
    fi
  done <<< "$clients_tsv"

  [[ -n "$batch" ]] || return 0
  hyprctl --batch "$batch" >/dev/null 2>&1 || true
}


compute_sig(){
  local layout="$1" ws="$2" forced_name="$3" forced_serial="$4" primary="$5"; shift 5
  local joined; joined="$(printf '%s,' "$@")"
  echo "layout=${layout};ws=${ws};f_name=${forced_name};f_ser=${forced_serial};p_pref_ser=${PRIMARY_PREFER_SERIAL};ipm=${INTERNAL_PANEL_MODE};ips=${INTERNAL_PANEL_SCALE};edm=${EXTERNAL_DEFAULT_MODE};eds=${EXTERNAL_DEFAULT_SCALE};primary=${primary};mons=${joined}"
}

# ============================================================
# Core apply
# ============================================================

handle_monitor_change_once(){
  # lock apply: per-invocation + guaranteed unlock
  local apply_lock="/tmp/monitor-autogen.apply.lock"
  exec 8>"$apply_lock"
  if ! flock -n 8; then
    log "apply lock busy -> skip"
    return 0
  fi
  trap 'flock -u 8 >/dev/null 2>&1 || true' RETURN

  load_settings
  load_state
  apply_runtime_overrides

  ensure_hypr_env || { log "no hypr session found -> skip"; return 0; }

  local json; json="$(get_stable_monitors_json)"
  mapfile -t names < <(get_monitor_names "$json")
  local count="${#names[@]}"
  (( count >= 1 )) || { log "no enabled monitors, skip"; return 0; }

  fill_monitor_props "$json"

  local primary; primary="$(choose_primary "${names[@]}")"
  mapfile -t secs < <(order_secondaries "$primary" "${names[@]}")
  local count_guess=$((1+${#secs[@]}))
  local layout="${LAST_LAYOUT:-$DEFAULT_LAYOUT}"
  local -a all=("$primary" "${secs[@]}")

  local sig; sig="$(compute_sig "$layout" "$WS_PER_MONITOR" "${FORCED_PRIMARY_NAME:-}" "${FORCED_PRIMARY_SERIAL:-}" "$primary" "${all[@]}")"
  local last_sig; last_sig="$(get_last_sig || true)"

  post_event_actions() {
    [[ "${EVENT_CONTEXT:-0}" == "1" ]] || return 0
    (
      # reset workspace view
      if [[ "${RESET_WS_VIEW_ON_EVENT:-1}" == "1" ]]; then
        sleep "${RESET_WS_VIEW_DELAY_SEC:-0.15}"
        reset_ws_view_all_monitors "${all[@]}" || true
      fi

      # recenter floating (only if offscreen)
      if [[ "${RECENTER_FLOATING_ON_EVENT:-1}" == "1" ]]; then
        sleep "${RECENTER_FLOATING_DELAY_SEC:-0.20}"
        recenter_floating_windows_if_offscreen "${all[@]}" || true
      fi
    ) &
  }

  if [[ "$sig" == "$last_sig" ]]; then
    log "unchanged sig -> skip (count=$count key=$(monitors_key "$json"))"
    post_event_actions
    return 0
  fi

  # prev/new totals for remap
  local prev_count="$LAST_MONITOR_COUNT"
  local prev_ws="$LAST_WS_PER_MONITOR"
  local removed=0
  (( prev_count > 0 && count < prev_count )) && removed=$((prev_count-count))

  local prev_total=0
  (( prev_count > 0 && prev_ws > 0 )) && prev_total=$((prev_count * prev_ws))

  local new_total=$((count * WS_PER_MONITOR))

  log "APPLY: count=$count key=$(monitors_key "$json") primary=$primary layout=$layout ws_per=$WS_PER_MONITOR prev_total=$prev_total new_total=$new_total removed=$removed"

  clean_generated_dir
  generate_profiles_from_json "$json"

  local fname="$OUT_DIR/multi${count_guess}-prim_$(sanitize "$primary")-${layout}.conf"
  ln -sf "$fname" "$CURRENT_FILE"

  LAST_PRIMARY_NAME="$primary"
  LAST_MONITOR_COUNT="$count"
  LAST_WS_PER_MONITOR="$WS_PER_MONITOR"
  save_state

  hyprctl reload >/dev/null 2>&1 || true

  # remap extra windows if range shrinks
  if [[ "${REMAP_EXTRA_WINDOWS:-1}" == "1" && "$prev_total" -gt 0 && "$new_total" -lt "$prev_total" ]]; then
    sleep "${REMAP_DELAY_SEC:-0.15}"
    if (( removed > 0 )) && [[ "${REMAP_MODE:-shift}" == "shift" ]] && (( prev_ws == WS_PER_MONITOR )); then
      remap_shift_to_range "$new_total" $((removed * WS_PER_MONITOR))
    else
      remap_modulo_to_range "$new_total"
    fi
  fi

  force_active_ws_in_range "$count" "$WS_PER_MONITOR"

  post_event_actions

  set_last_sig "$sig"

  # if [[ "${FORCE_RESTART_WAYBAR_ON_EVENT:-1}" == "1" ]]; then
  #   log "waybar restart scheduled"
  #   restart_waybar
  # fi
}

reconcile_window(){
  local start; start="$(date +%s)"
  local last_key="" stable=0

  while true; do
    handle_monitor_change_once || true

    local json; json="$(get_monitors_json)"
    local key; key="$(monitors_key "$json")"

    if [[ "$key" == "$last_key" && -n "$key" ]]; then
      stable=$((stable+1))
    else
      stable=0
      last_key="$key"
    fi

    (( stable >= 2 )) && { log "reconcile stable key=$key"; break; }

    local now; now="$(date +%s)"
    (( now - start >= RECONCILE_WINDOW_SEC )) && { log "reconcile timeout (last key=$key)"; break; }

    sleep "$RECONCILE_STEP_SEC"
  done
}

poll_loop(){
  while true; do
    sleep "$POLL_SEC"
    handle_monitor_change_once || true
  done
}

# ============================================================
# Commands
# ============================================================

apply_cmd(){
  local layout="${1:?layout required}"
  load_settings; load_state; apply_runtime_overrides
  LAST_LAYOUT="$layout"; save_state
  EVENT_CONTEXT=1
  reconcile_window
  EVENT_CONTEXT=0
}

set_primary_cmd(){
  local mon="${1:?monitor required}"
  load_settings; load_state; apply_runtime_overrides
  FORCED_PRIMARY_NAME="$mon"; save_state
  EVENT_CONTEXT=1
  reconcile_window
  EVENT_CONTEXT=0
}

clear_primary_cmd(){
  load_settings; load_state; apply_runtime_overrides
  FORCED_PRIMARY_NAME=""; save_state
  EVENT_CONTEXT=1
  reconcile_window
  EVENT_CONTEXT=0
}

set_primary_serial_cmd(){
  local serial="${1:?serial required}"
  load_settings; load_state; apply_runtime_overrides
  FORCED_PRIMARY_SERIAL="$serial"; save_state
  EVENT_CONTEXT=1
  reconcile_window
  EVENT_CONTEXT=0
}

clear_primary_serial_cmd(){
  load_settings; load_state; apply_runtime_overrides
  FORCED_PRIMARY_SERIAL=""; save_state
  EVENT_CONTEXT=1
  reconcile_window
  EVENT_CONTEXT=0
}

set_ws_per_monitor_cmd(){
  local n="${1:?number required}"
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "WS_PER_MONITOR must be an integer" >&2; exit 2; }
  (( n >= 1 && n <= 20 )) || { echo "WS_PER_MONITOR out of range (1..20)" >&2; exit 2; }
  load_settings; load_state
  WS_PER_MONITOR_OVERRIDE="$n"
  save_state
  EVENT_CONTEXT=1
  reconcile_window
  EVENT_CONTEXT=0
}

clear_ws_per_monitor_cmd(){
  load_settings; load_state
  WS_PER_MONITOR_OVERRIDE=""
  save_state
  EVENT_CONTEXT=1
  reconcile_window
  EVENT_CONTEXT=0
}

list_monitors(){
  ensure_hypr_env || { echo "No Hyprland session found" >&2; exit 1; }
  hyprctl monitors -j | jq -r '
    sort_by(.id)[]
    | select((.name//"")!="")
    | "\(.id)\t\(.name)\tdisabled=\(.disabled//false)\t\(.width//0)x\(.height//0)@\(.refreshRate//0)\tscale=\(.scale//1)\tserial=\(.serial//"")"
  '
}

status(){
  load_settings; load_state; apply_runtime_overrides
  echo "WS_PER_MONITOR=$WS_PER_MONITOR (override=${WS_PER_MONITOR_OVERRIDE:-none})"
  echo "layout=${LAST_LAYOUT:-$DEFAULT_LAYOUT}"
  echo "forced_primary_name=${FORCED_PRIMARY_NAME:-none}"
  echo "forced_primary_serial=${FORCED_PRIMARY_SERIAL:-none}"
  echo "prefer_primary_serial=${PRIMARY_PREFER_SERIAL:-none}"
  echo "RESET_WS_VIEW_ON_EVENT=$RESET_WS_VIEW_ON_EVENT delay=$RESET_WS_VIEW_DELAY_SEC"
  echo "RECENTER_FLOATING_ON_EVENT=$RECENTER_FLOATING_ON_EVENT only_if_offscreen=$RECENTER_FLOATING_ONLY_IF_OFFSCREEN delay=$RECENTER_FLOATING_DELAY_SEC"
  echo "CURRENT_FILE=$CURRENT_FILE -> $(readlink -f "$CURRENT_FILE" 2>/dev/null || echo "$CURRENT_FILE")"
  echo "LAST_SIG_FILE=$LAST_SIG_FILE"
  echo "LOG_FILE=$LOG_FILE"
}

# ============================================================
# Listener: survives logout/login by reattaching to new signature
# ============================================================

listen(){
  require_cmd socat; require_cmd jq; require_cmd hyprctl; require_cmd tr; require_cmd flock

  # lock SOLO per evitare 2 listener
  local lockfile="${LOCKFILE:-/tmp/monitor-autogen.lock}"
  exec 9>"$lockfile"
  if ! flock -n 9; then
    echo "monitor-autogen: listener già in esecuzione (lock attivo: $lockfile)" >&2
    exit 0
  fi

  log "listener start pid=$$ (auto-reattach across logout/login)"

  local poll_pid=""

  cleanup_listen() {
    [[ -n "${poll_pid:-}" ]] && kill "$poll_pid" >/dev/null 2>&1 || true
    wait "$poll_pid" >/dev/null 2>&1 || true
  }
  trap cleanup_listen EXIT INT TERM

  while true; do
    local sig sock

    sig="$(resolve_hypr_sig)"
    if [[ -z "$sig" ]]; then
      sleep 0.5
      continue
    fi

    export HYPRLAND_INSTANCE_SIGNATURE="$sig"
    sock="$XDG_RUNTIME_DIR/hypr/$sig/.socket2.sock"

    if [[ ! -S "$sock" ]]; then
      sleep 0.5
      continue
    fi

    log "attach hypr sig=$sig sock=$sock"

    # treat attach as event: align ws view + floating if needed
    EVENT_CONTEXT=1
    reconcile_window
    EVENT_CONTEXT=0

    poll_loop &
    poll_pid=$!

    while IFS= read -r line; do
      case "$line" in
        monitoradded*|monitorremoved*|monitoraddedv2*|monitorremovedv2*)
          log "event: $line"
          sleep "$DEBOUNCE_SEC"
          EVENT_CONTEXT=1
          reconcile_window
          EVENT_CONTEXT=0
          ;;
      esac
    done < <(socat -u "UNIX-CONNECT:$sock" - 2>/dev/null | tr -d '\r' || true)

    log "socket closed for sig=$sig -> reattach"

    kill "$poll_pid" >/dev/null 2>&1 || true
    wait "$poll_pid" >/dev/null 2>&1 || true
    poll_pid=""
    sleep 0.3
  done
}

usage(){
  cat <<EOF
Usage:
  monitor-autogen.sh listen
  monitor-autogen.sh apply <layout>
  monitor-autogen.sh set-primary <MONITOR>
  monitor-autogen.sh clear-primary
  monitor-autogen.sh set-primary-serial <SERIAL>
  monitor-autogen.sh clear-primary-serial
  monitor-autogen.sh set-ws-per-monitor <N>
  monitor-autogen.sh clear-ws-per-monitor
  monitor-autogen.sh list-monitors
  monitor-autogen.sh status
EOF
}

main(){
  require_cmd jq; require_cmd hyprctl; require_cmd flock

  case "$CMD" in
    listen) listen ;;
    apply) apply_cmd "$@" ;;
    set-primary) set_primary_cmd "$@" ;;
    clear-primary) clear_primary_cmd ;;
    set-primary-serial) set_primary_serial_cmd "$@" ;;
    clear-primary-serial) clear_primary_serial_cmd ;;
    set-ws-per-monitor) set_ws_per_monitor_cmd "$@" ;;
    clear-ws-per-monitor) clear_ws_per_monitor_cmd ;;
    list-monitors) list_monitors ;;
    status) status ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
