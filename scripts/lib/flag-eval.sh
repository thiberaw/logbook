#!/usr/bin/env bash
# =============================================================================
# flag-eval.sh — eval engine for the flag-analysis golden corpus  [LIBRARY]
#
# WHAT IT IS:  the reusable engine behind scripts/tests/test-flag-analysis.sh.
#              Separated from the prompt (flag-analysis.sh) and the corpus
#              (fixtures/flag-corpus.tsv) so the matrix/metric/gate logic is
#              unit-testable WITHOUT real model calls (see test-flag-eval.sh).
# SOURCED BY:  scripts/tests/test-flag-analysis.sh  (real model, gated)
#              scripts/tests/test-flag-eval.sh       (stubbed model, free)
# REQUIRES:    the sourcing script must ALSO source lib/flag-analysis.sh first
#              (provides FLAG_ANALYSIS_MODEL, build_flag_prompt, extract_flag_json).
# =============================================================================

# _one_verdict — single model run; prints "confirm", "clear", or "invalid".
# Ported verbatim from test-flag-analysis.sh (2026-06-29) — no behavior change.
_one_verdict() {
  local prompt="$1" raw json issue
  raw=$(echo "$prompt" | LOGBOOK_ANALYZER=1 claude --print --model "$FLAG_ANALYSIS_MODEL")
  json=$(extract_flag_json "$raw")
  if ! printf '%s' "$json" | jq empty 2>/dev/null; then
    echo "invalid"
    return 0
  fi
  issue=$(printf '%s' "$json" | jq -r 'if .issue == null then "" else .issue end')
  if [ -n "$issue" ]; then echo "confirm"; else echo "clear"; fi
}

# VERDICT_FN — the function the engine calls to get one verdict. Overridable so
# the engine's own test can substitute a deterministic stub. Default = real model.
VERDICT_FN="${VERDICT_FN:-_one_verdict}"

# _majority_label — run VERDICT_FN up to 3x; print the MAJORITY label among
# confirm/clear/invalid. Short-circuits when a label reaches 2. On a 3-way tie
# (one each) returns the highest count with tie-break order confirm>clear>invalid.
# Unlike the old match-vs-expect loop this returns the PREDICTED label, so the
# confusion matrix can be built; the per-case gate (label == expected) is
# equivalent to the old majority check.
_majority_label() {
  local prompt="$1" v i conf=0 clr=0 inv=0
  for i in 1 2 3; do
    v=$("$VERDICT_FN" "$prompt")
    case "$v" in
      confirm) conf=$((conf+1)) ;;
      clear)   clr=$((clr+1)) ;;
      *)       inv=$((inv+1)) ;;
    esac
    [ "$conf" -ge 2 ] && { echo "confirm"; return 0; }
    [ "$clr"  -ge 2 ] && { echo "clear";   return 0; }
    [ "$inv"  -ge 2 ] && { echo "invalid"; return 0; }
  done
  # No 2-majority in 3 runs: pick the max, tie-break confirm > clear > invalid.
  if [ "$conf" -ge "$clr" ] && [ "$conf" -ge "$inv" ]; then echo "confirm"
  elif [ "$clr" -ge "$inv" ]; then echo "clear"
  else echo "invalid"; fi
}

# print_scorecard — print the confusion matrix + derived metrics. Pure arithmetic.
# args: tp fp fn tn invalid model
# Raw counts lead; metrics print as fractions under an N banner; zero den -> n/a.
print_scorecard() {
  local tp="$1" fp="$2" fn="$3" tn="$4" inv="$5" model="$6"
  local n=$(( tp + fp + fn + tn + inv ))
  local prec rec acc
  prec=$(_frac "$tp" "$(( tp + fp ))")
  rec=$(_frac  "$tp" "$(( tp + fn ))")
  acc=$(_frac  "$(( tp + tn ))" "$(( tp + fp + fn + tn ))")
  echo "--- scorecard (corpus: ${n} fixtures · model ${model}) ---"
  echo "confusion matrix (counts — read these first):"
  echo "           pred:confirm  pred:clear"
  printf 'act:confirm  %6d        %4d\n' "$tp" "$fn"
  printf 'act:clear    %6d        %4d\n' "$fp" "$tn"
  [ "$inv" -gt 0 ] && echo "invalid predictions (counted as regressions): ${inv}"
  echo "derived (N=${n} — DIRECTIONAL ONLY, NOT a statistic):"
  echo "  precision ${prec}   recall ${rec}   accuracy ${acc}"
}

# _frac num den -> "num/den = X.XX" or "n/a" when den == 0.
_frac() {
  local num="$1" den="$2"
  if [ "$den" -eq 0 ]; then echo "n/a"; return 0; fi
  LC_ALL=C awk "BEGIN {printf \"%d/%d = %.2f\", $num, $den, $num/$den}"
}

# run_corpus — read a TSV manifest, eval each fixture, print per-case lines +
# scorecard, return non-zero if ANY case's majority label != expected.
# Each row: fixture_file<TAB>expected<TAB>+9 metric args (build_flag_prompt args 2..10).
run_corpus() {
  local manifest="$1"
  local tp=0 fp=0 fn=0 tn=0 inv=0 regress=0
  local line fixture expected reasons project branch dur cost turns calls errs files
  local condensed prompt label
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip blank lines and # comments.
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    # Arity guard: split on tab; must be exactly 11 columns = (fixture_file,
    # expected) + the 9 build_flag_prompt metric args. A wrong count means the
    # manifest drifted from the prompt signature -> hard error, not a silent skip.
    local -a cols
    IFS=$'\t' read -r -a cols <<< "$line"
    if [ "${#cols[@]}" -ne 11 ]; then
      echo "ERROR: manifest row has ${#cols[@]} columns, expected 11: $line" >&2
      return 1
    fi
    fixture="${cols[0]}"; expected="${cols[1]}"; reasons="${cols[2]}"
    project="${cols[3]}"; branch="${cols[4]}"; dur="${cols[5]}"; cost="${cols[6]}"
    turns="${cols[7]}"; calls="${cols[8]}"; errs="${cols[9]}"; files="${cols[10]}"

    if [ ! -f "$FIXTURES/$fixture" ]; then
      echo "ERROR: fixture not found: $FIXTURES/$fixture" >&2
      return 1
    fi
    condensed=$(cat "$FIXTURES/$fixture")
    prompt=$(build_flag_prompt "$condensed" "$reasons" "$project" "$branch" \
      "$dur" "$cost" "$turns" "$calls" "$errs" "$files")
    label=$(_majority_label "$prompt")

    if [ "$label" = "$expected" ]; then
      echo "PASS $fixture — '$label'"
    else
      echo "FAIL $fixture — expected '$expected' got '$label'"
      regress=$((regress+1))
    fi
    case "$expected/$label" in
      confirm/confirm) tp=$((tp+1)) ;;
      clear/confirm)   fp=$((fp+1)) ;;
      confirm/clear)   fn=$((fn+1)) ;;
      clear/clear)     tn=$((tn+1)) ;;
      */invalid)       inv=$((inv+1)) ;;
    esac
  done < "$manifest"

  print_scorecard "$tp" "$fp" "$fn" "$tn" "$inv" "$FLAG_ANALYSIS_MODEL"
  if [ "$regress" -eq 0 ]; then
    echo "GATE: PASS (0 cases regressed)"; return 0
  else
    echo "GATE: FAIL ($regress cases regressed)"; return 1
  fi
}
