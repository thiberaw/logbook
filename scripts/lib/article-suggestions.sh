#!/usr/bin/env bash
# =============================================================================
# article-suggestions.sh — pick + render article/release suggestions  [LIBRARY — sourced, not run]
#
# WHAT IT IS: a library of shell functions. It is sourced by other scripts, not
#   executed directly. It chooses fresh (unseen) articles and Claude release
#   notes from a cached feed, optionally prints them with `gum` styling, and
#   records them into the day's JSON so they appear in the report.
#
# SOURCED BY (to find callers):  grep -rl 'article-suggestions.sh' scripts/
#
# PROVIDES:
#   _select_articles                 (internal) load cache, drop already-seen, split releases vs articles
#   _render_entries                  (internal) print a JSON list of entries with gum styling
#   show_article_suggestions         select + print to terminal + write to daily JSON
#   show_article_suggestions_silent  select + write to daily JSON only (no terminal output)
#   _write_articles_to_daily         (internal) persist selections to daily JSON + update "seen" hashes
#
# Depends on config vars from config.sh ($STATE_DIR, $DAILY_DIR), the I18N_*
# strings from i18n.sh, and log helpers (log_info / log_warn).
# =============================================================================
# Article suggestions for morning review.
# Reads from .state/articles-cache.json, filters seen, selects top articles.
# Two modes:
#   show_article_suggestions       — TUI display + write to daily JSON
#   show_article_suggestions_silent — write to daily JSON only (no TUI output)
# Usage: source this file, then call the desired function

# Internal: load cache, filter seen entries, split releases from regular articles.
# Sets outer variables:
#   _sa_releases    — JSON array of unseen release-note entries (is_release: true), no cap
#   _sa_selected    — JSON array of unseen non-release articles, capped at max_articles
#   _sa_daily_file, _sa_seen_file, _sa_seen_hashes
# Returns 0 if anything was selected, 1 otherwise.
_select_articles() {
  local cache_file="$STATE_DIR/articles-cache.json"   # the fetched feed of candidate articles
  local max_articles=4                                # cap on non-release articles to surface
  local today
  today=$(date +%Y-%m-%d)

  _sa_seen_file="$STATE_DIR/articles-seen.json"        # rolling list of already-shown url hashes
  _sa_daily_file="$DAILY_DIR/$today.json"              # today's JSON, where selections get written

  # Skip if no cache
  if [ ! -f "$cache_file" ]; then                      # -f = path exists and is a regular file
    log_warn "article-suggestions: no cache at $cache_file — skipped"
    return 1
  fi

  # Load seen hashes (use file, not shell variable, to avoid control-char issues).
  # We only use the seen file if it exists AND parses as a JSON array; otherwise
  # we treat "seen" as unknown (empty) and skip the filter below.
  _sa_seen_hashes="[]"
  if [ -f "$_sa_seen_file" ] && jq 'type == "array"' "$_sa_seen_file" >/dev/null 2>&1; then
    _sa_seen_hashes="$_sa_seen_file"                   # hold the FILE PATH, not the contents
  else
    _sa_seen_hashes=""
  fi

  # Build unseen list, then split releases (no cap) from regular articles (capped).
  local _split_json
  if [ -n "$_sa_seen_hashes" ]; then
    # --slurpfile seen reads the seen-hashes file into $seen (an array-of-arrays,
    #   so the actual list is $seen[0]). --argjson max passes the numeric cap.
    # jq pipeline:
    #   - add a url_hash (base64 of the url) to every article
    #   - keep only those whose hash is NOT already in the seen list -> $unseen
    #   - releases: entries flagged is_release==true, sorted by priority (no cap)
    #   - articles: the rest, sorted by priority, then sliced to the first $max (.[:$max])
    # 2>/dev/null || echo '{...}' = if jq errors, fall back to an empty result.
    # Articles: prefer unseen ("fresh"); if none are unseen, fall back to the
    # top already-seen non-release articles tagged {stale:true} so an empty-feed
    # day still surfaces reading rather than a blank section. Releases stay
    # unseen-only (the stale fallback is scoped to articles by request).
    _split_json=$(jq --slurpfile seen "$_sa_seen_hashes" --argjson max "$max_articles" '
      ([.articles[] | . + {url_hash: (.url | @base64)}]) as $all
      | ($all | map(select(.url_hash as $h | $seen[0] | index($h) | not))) as $unseen
      | ($unseen | map(select(.is_release != true)) | sort_by(.priority) | .[:$max]) as $fresh
      | {
          releases: ($unseen | map(select(.is_release == true)) | sort_by(.priority)),
          articles: (
            if ($fresh | length) > 0 then $fresh
            else ($all | map(select(.is_release != true)) | sort_by(.priority) | .[:$max] | map(. + {stale: true}))
            end
          )
        }
    ' "$cache_file" 2>/dev/null || echo '{"releases":[],"articles":[]}')
  else
    # No usable seen list: every article counts as unseen (no filtering step).
    _split_json=$(jq --argjson max "$max_articles" '
      ([.articles[] | . + {url_hash: (.url | @base64)}]) as $unseen
      | {
          releases: ($unseen | map(select(.is_release == true)) | sort_by(.priority)),
          articles: ($unseen | map(select(.is_release != true)) | sort_by(.priority) | .[:$max])
        }
    ' "$cache_file" 2>/dev/null || echo '{"releases":[],"articles":[]}')
  fi

  # Split the combined result into the two outer variables the callers read.
  _sa_releases=$(printf '%s' "$_split_json" | jq '.releases')
  _sa_selected=$(printf '%s' "$_split_json" | jq '.articles')

  local rel_count art_count stale_count cache_count
  rel_count=$(printf '%s\n' "$_sa_releases" | jq 'length')   # how many releases selected
  art_count=$(printf '%s\n' "$_sa_selected" | jq 'length')   # how many articles selected
  stale_count=$(printf '%s\n' "$_sa_selected" | jq '[.[] | select(.stale == true)] | length')  # of which re-surfaced
  # ${rel_count:-0} = use 0 if the var is empty/unset, so the -lt numeric test is safe.
  if [ "${rel_count:-0}" -lt 1 ] && [ "${art_count:-0}" -lt 1 ]; then
    cache_count=$(jq '.articles | length' "$cache_file" 2>/dev/null || echo 0)
    log_warn "article-suggestions: 0 selected (cache=$cache_count, all filtered as already-seen)"
    return 1
  fi

  log_info "article-suggestions: selected ${rel_count:-0} releases + ${art_count:-0} articles (${stale_count:-0} re-surfaced stale)"
  return 0
}

# Internal: render a list of entries (releases or articles) with gum styling.
_render_entries() {
  local entries="$1"
  # jq builds, for each entry, up to three lines of text:
  #   "N. <title>"      (1-based index; title truncated to 78 chars)
  #   "   <url>"        (3-space indented)
  #   "   <desc>"       (only if the cleaned description is > 10 chars; capped at 120)
  # to_entries gives {key,value} pairs so .key is the 0-based index (+1 for display).
  # The gsub() chain cleans the raw feed description in order:
  #   &#NN;       numeric HTML entities -> space
  #   &name;      named HTML entities   -> space
  #   submitted by.*   trailing aggregator boilerplate -> removed
  #   <...> / <.. (unclosed) HTML tags  -> removed
  #   \s+         whitespace runs       -> single space
  #   ^ +| +$     leading/trailing space-> removed
  printf '%s\n' "$entries" | jq -r 'to_entries[] |
    .value as $a |
    (($a.description // "")
      | gsub("&#[0-9]+;"; " ") | gsub("&[a-z]+;"; " ")
      | gsub("submitted by.*"; "")
      | gsub("<[^>]*>"; "") | gsub("<[^>]*$"; "")
      | gsub("\\s+"; " ") | gsub("^ +| +$"; "")
    ) as $desc |
    "\(.key + 1). \($a.title | if length > 78 then .[0:75] + "..." else . end)\(if $a.stale == true then " (previously shown)" else "" end)" +
    "\n   \($a.url)" +
    (if ($desc | length) > 10 then "\n   \($desc | if length > 120 then .[0:117] + "..." else . end)" else "" end)
  ' | while IFS= read -r line; do
    # Color each emitted line by what it is. [[ "$x" == "prefix"* ]] = glob match on the prefix.
    if [[ "$line" == "   http"* ]]; then
      gum style --foreground 39 "  $line"    # URL line -> blue
    elif [[ "$line" == "   "* ]]; then
      gum style --foreground 245 "  $line"   # description line -> grey
    else
      echo "  $line"                          # title/index line -> plain
    fi
  done || :                                    # `|| :` = swallow a non-zero exit so set -e won't abort
}

show_article_suggestions() {
  # If nothing was selected, _select_articles returns non-zero -> bail out quietly
  # (return 0 so a sourcing caller under `set -e` is not aborted).
  _select_articles || return 0

  # Releases block first (pinned, no cap)
  if [ "$(printf '%s' "$_sa_releases" | jq 'length')" -gt 0 ]; then
    echo ""
    gum style --foreground 220 --bold "$I18N_RELEASES_TITLE"   # yellow, localized heading
    _render_entries "$_sa_releases"
  fi

  # Suggested reading
  if [ "$(printf '%s' "$_sa_selected" | jq 'length')" -gt 0 ]; then
    echo ""
    gum style --foreground 81 --bold "$I18N_ARTICLES_TITLE"    # cyan, localized heading
    _render_entries "$_sa_selected"
  fi
  echo ""

  # Write to daily JSON and update seen hashes
  _write_articles_to_daily "$_sa_daily_file" "$_sa_releases" "$_sa_selected" "$_sa_seen_file"
}

# Silent version: select entries and write to daily JSON without TUI display
show_article_suggestions_silent() {
  _select_articles || return 0   # bail quietly if nothing selected (see above)

  _write_articles_to_daily "$_sa_daily_file" "$_sa_releases" "$_sa_selected" "$_sa_seen_file"
}

# Internal: write selected releases + articles to daily JSON and update seen hashes
_write_articles_to_daily() {
  local daily_file="$1"
  local releases="$2"
  local selected="$3"
  local seen_file="$4"

  # Record seen hashes from BOTH releases and articles (use temp files to avoid zsh echo mangling JSON)
  local tmp_new tmp_releases tmp_selected
  tmp_new=$(mktemp)                          # mktemp = create a unique temp file, returns its path
  tmp_releases=$(mktemp)
  tmp_selected=$(mktemp)
  printf '%s\n' "$releases" > "$tmp_releases"   # stash the JSON arrays in files for jq
  printf '%s\n' "$selected" > "$tmp_selected"
  # jq -s (slurp) reads both files into one array [releases, articles]; concatenate
  # them (.[0] + .[1]) and pull out just the url_hash of every entry -> new seen hashes.
  jq -s '(.[0] + .[1]) | [.[].url_hash]' "$tmp_releases" "$tmp_selected" > "$tmp_new"

  if [ -f "$seen_file" ]; then
    # Merge old + new seen hashes and keep only the most recent 200 (.[-200:] = last 200),
    # so the seen list does not grow without bound. Write to a temp, then atomically mv.
    jq -s '(.[0] + .[1]) | .[-200:]' "$seen_file" "$tmp_new" > "${tmp_new}.merged" && mv "${tmp_new}.merged" "$seen_file"
  else
    mv "$tmp_new" "$seen_file"               # first run: just use the new list as-is
  fi

  # Write to daily JSON
  if [ -f "$daily_file" ]; then
    local tmp_daily
    tmp_daily=$(mktemp)
    # Project each entry down to just the fields the report needs (drop url_hash etc.).
    jq '[.[] | {title, url, source_domain, description, published}]' "$tmp_releases" > "${tmp_releases}.releases"
    jq '[.[] | {title, url, source_domain, description} + (if .stale == true then {stale: true} else {} end)]' "$tmp_selected" > "${tmp_selected}.articles"
    # Merge those two arrays into the existing daily JSON under fixed keys.
    # --slurpfile X reads a file into $X (array-of-docs, so the doc is $X[0]).
    jq --slurpfile releases "${tmp_releases}.releases" --slurpfile articles "${tmp_selected}.articles" '
      .claude_releases = $releases[0]
      | .suggested_articles = $articles[0]
    ' "$daily_file" > "$tmp_daily" && mv "$tmp_daily" "$daily_file"   # mv only if jq succeeded
    rm -f "${tmp_releases}.releases" "${tmp_selected}.articles"
  fi

  rm -f "$tmp_new" "$tmp_releases" "$tmp_selected"   # clean up temp files
}
