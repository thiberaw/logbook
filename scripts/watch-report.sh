#!/usr/bin/env bash
# =============================================================================
# watch-report.sh — read-only evidence reporter for open-concerns watch items.
#
# WHAT IT IS:  for each item in docs/watch-items.json, prints the computed half
#              of its close/reopen condition next to the item's summary. EVIDENCE,
#              NEVER A VERDICT — no CLOSE/REOPEN/"evidence supports" string is ever
#              emitted. Items with metric:null print as a visible gap. Reads SQLite
#              + hook audit logs; writes nothing.
# MODES:       default            = coloured TUI, items sorted attention-first
#                                   (orange out-of-target/unavailable → green
#                                   in-target → grey not-measured). Consumed by
#                                   morning-review.sh (printed raw). NO_COLOR blanks
#                                   the colour.
#              --report           = plain, colour-free text with each metric's
#                                   spot-check rows rendered, for /improve to read.
# OVERRIDES:   WATCH_ITEMS_FILE (registry path, for tests).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/lib/sessions-db.sh"
source "$SCRIPT_DIR/lib/watch-metrics.sh"

WATCH_ITEMS_FILE="${WATCH_ITEMS_FILE:-$DOCS_DIR/watch-items.json}"

validate_registry() {
  local f="$1"
  jq empty "$f" 2>/dev/null || { echo "watch-report: $f is not valid JSON" >&2; exit 1; }
  jq -e 'type=="array"' "$f" >/dev/null || { echo "watch-report: $f is not a JSON array" >&2; exit 1; }
  local bad
  bad=$(jq -r '.[] | select((has("id") and has("concern_ref") and has("summary") and has("metric"))|not) | .id // "<no-id>"' "$f")
  [ -n "$bad" ] && { echo "watch-report: entry '$bad' is missing a required field (id/concern_ref/summary/metric)" >&2; exit 1; }
  local dup
  dup=$(jq -r '[.[].id] | group_by(.) | map(select(length>1)[0]) | .[]' "$f")
  [ -n "$dup" ] && { echo "watch-report: duplicate id '$dup' in registry" >&2; exit 1; }
  local m
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    declare -F "wm_$m" >/dev/null || { echo "watch-report: entry metric '$m' has no wm_$m function in watch-metrics.sh" >&2; exit 1; }
  done < <(jq -r '.[] | select(.metric != null) | .metric' "$f")
}

validate_registry "$WATCH_ITEMS_FILE"

MODE="${1:-tui}"   # default = coloured TUI; --report = plain text for /improve

render_report() {   # plain, colour-free, rows-bearing — for the LLM consumer
  echo "WATCH ITEMS — computed evidence as of $(date +%Y-%m-%d)"
  echo ""
  while IFS= read -r entry; do
    summary=$(echo "$entry" | jq -r '.summary')
    concern=$(echo "$entry" | jq -r '.concern_ref')
    metric=$(echo "$entry" | jq -r 'if .metric==null then "" else .metric end')
    needs=$(echo "$entry" | jq -r '.needs_judgment // ""')
    if [ -z "$metric" ]; then
      printf '%s  [%s]\n  not yet measured\n\n' "$summary" "$concern"
      continue
    fi
    windows=$(echo "$entry" | jq -r '.windows // 2')
    params=$(echo "$entry" | jq -c '.params // {}')
    result=$(wm_"$metric" "$windows" "$params")
    status=$(echo "$result" | jq -r '.status')
    computed=$(echo "$result" | jq -r '.computed')
    mechanical=$(echo "$result" | jq -r '.mechanical')
    printf '%s  [%s]\n' "$summary" "$concern"
    printf '  metric: %s\n' "$metric"
    if [ "$status" = "unavailable" ]; then
      printf '  %s\n\n' "$computed"
      continue
    fi
    printf '  result: %s\n' "$mechanical"
    printf '  per-window: %s\n' "$computed"
    local rows; rows=$(echo "$result" | jq -r '.rows[]?')
    if [ -n "$rows" ]; then
      printf '  rows (spot-check candidates):\n'
      printf '%s\n' "$rows" | sed 's/^/    - /'
    fi
    # Intervention ledger: if this item records a shipped change, show the honest
    # before/after around its date so the loop can see whether the change moved the
    # metric — or whether (as with 2026-06-22) the win came from a model release.
    local intervention; intervention=$(echo "$entry" | jq -c '.intervention // empty')
    if [ -n "$intervention" ]; then
      local iv_date iv_base iv_dir iv_note
      iv_date=$(echo "$intervention" | jq -r '.date')
      iv_base=$(echo "$intervention" | jq -r '.baseline // "?"')
      iv_dir=$(echo "$intervention" | jq -r '.expected_direction // "?"')
      iv_note=$(echo "$intervention" | jq -r '.note // ""')
      printf '  intervention: %s — baseline %s\n' "$iv_date" "$iv_base"
      printf '    expected: %s\n' "$iv_dir"
      [ -n "$iv_note" ] && printf '    note: %s\n' "$iv_note"
      if declare -F "wm_${metric}_split" >/dev/null; then
        printf '    before/after: %s\n' "$(wm_"${metric}_split" "$iv_date")"
      else
        printf '    before/after: (no split computation for metric %s)\n' "$metric"
      fi
    fi
    [ -n "$needs" ] && printf '  your call: %s\n' "$needs"
    echo ""
  done < <(jq -c '.[]' "$WATCH_ITEMS_FILE")
}

if [ "$MODE" = "--report" ]; then
  render_report
  exit 0
fi

if [ -n "${NO_COLOR:-}" ]; then
  C_ORANGE='' C_GREEN='' C_GREY='' C_RESET=''
else
  C_ORANGE=$'\033[38;5;214m' C_GREEN=$'\033[38;5;82m' C_GREY=$'\033[38;5;245m' C_RESET=$'\033[0m'
fi

echo "WATCH ITEMS — computed evidence as of $(date +%Y-%m-%d)"
echo ""

orange='' green='' grey=''   # tier buffers, printed orange -> green -> grey

while IFS= read -r entry; do
  summary=$(echo "$entry" | jq -r '.summary')
  metric=$(echo "$entry" | jq -r 'if .metric==null then "" else .metric end')
  needs=$(echo "$entry" | jq -r '.needs_judgment // ""')

  if [ -z "$metric" ]; then
    grey+="$(printf '%s· %s   not yet measured%s' "$C_GREY" "$summary" "$C_RESET")"$'\n'
    continue
  fi

  windows=$(echo "$entry" | jq -r '.windows // 2')
  params=$(echo "$entry" | jq -c '.params // {}')
  result=$(wm_"$metric" "$windows" "$params")
  status=$(echo "$result" | jq -r '.status')
  computed=$(echo "$result" | jq -r '.computed')
  mechanical=$(echo "$result" | jq -r '.mechanical')
  in_target=$(echo "$result" | jq -r '.in_target')

  if [ "$status" = "unavailable" ]; then
    orange+="$(printf '%s⚠ %s   %s%s' "$C_ORANGE" "$summary" "$computed" "$C_RESET")"$'\n'
    continue
  fi

  case "$in_target" in
    true)  glyph='✓'; col="$C_GREEN";  tier=green ;;
    false) glyph='⚠'; col="$C_ORANGE"; tier=orange ;;
    *)     glyph='·'; col="$C_GREY";   tier=grey ;;   # null = metric ran, no data yet
  esac

  block="$(printf '%s%s %s   %s%s' "$col" "$glyph" "$summary" "$mechanical" "$C_RESET")"$'\n'
  if [ -n "$needs" ]; then
    if [ "$tier" = green ]; then yc="$C_GREY"; else yc="$col"; fi
    block+="$(printf '%s     your call: %s%s' "$yc" "$needs" "$C_RESET")"$'\n'
  fi

  case "$tier" in
    orange) orange+="$block" ;;
    green)  green+="$block" ;;
    grey)   grey+="$block" ;;
  esac
done < <(jq -c '.[]' "$WATCH_ITEMS_FILE")

printf '%s%s%s' "$orange" "$green" "$grey"
