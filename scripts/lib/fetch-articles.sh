#!/usr/bin/env bash
# =============================================================================
# fetch-articles.sh — gather & filter AI-coding article suggestions  [LIBRARY but also runnable standalone]
#
# WHAT IT IS:  fetches recent articles/releases from many web sources, filters
#              them down to AI-coding-relevant items, and caches the result.
# ITS JOB:     produce .state/articles-cache.json for the morning-review skill.
# INPUT:       none (no args / no stdin). Reads config.sh for $STATE_DIR.
# IT CALLS:    curl (download feeds/pages), python3 (parse XML/HTML), jq (filter
#              & merge JSON), gh (GitHub releases API), and logging.sh helpers.
# CALLED BY:   session-end.sh (in the background) or inline as a fallback.
#
# HOW TO READ THIS FILE — runs top to bottom, in these sections:
#   [setup]                  strict mode, source libs, compute date cutoffs
#   [parse_feed]             generic RSS/Atom feed parser (curl -> python3)
#   [merge_feed]             append one source's JSON into the running list
#   [fetch_hn]               Hacker News via Algolia API (jq)
#   [fetch_claude_code_releases]   Claude Code GitHub releases (gh + jq)
#   [fetch_anthropic_api_releases] platform.claude.com release notes (scrape)
#   [fetch_anthropic_news]   anthropic.com/news announcements (scrape)
#   [fetch_anthropic]        anthropic.com engineering/research blogs (scrape)
#   [fetch all sources]      run every fetcher above, merging into one list
#   [keyword filter]         keep only AI-coding-relevant items
#   [exclude low-value]      drop questions/anecdotes/announcements
#   [reddit quality filter]  extra-strict bar for noisy Reddit source
#   [dedupe / sort / write]  final cleanup and write the cache file
# =============================================================================

# --- [setup] -----------------------------------------------------------------
# Strict-ish mode. -u: using an unset variable is an error; -o pipefail: a
# pipeline fails if ANY stage fails. (Note: -e is intentionally NOT set here, so
# an individual source that fails won't abort the whole run.)
set -uo pipefail

# Absolute path to the directory holding THIS script, so we can source siblings
# regardless of where the script was invoked from.
# BASH_SOURCE[0] = this file's path; `cd ... && pwd` resolves it to an absolute dir.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"   # defines $STATE_DIR (must be sourced first)
source "$SCRIPT_DIR/logging.sh"     # provides log_info / log_warn / log_error

CACHE_FILE="$STATE_DIR/articles-cache.json"   # final output written here
FETCH_TIMEOUT=5                               # per-request seconds cap (passed to curl)
MERGE_FILE=$(mktemp)   # temp JSON file that accumulates every source's results

# `trap ... EXIT` runs this cleanup automatically when the script exits (any reason),
# so the temp file is always removed.
cleanup() { rm -f "$MERGE_FILE"; }
trap cleanup EXIT

# Date cutoffs as Unix epoch seconds. Each line tries the GNU `date -d` form first,
# and if that fails (e.g. on macOS/BSD) falls back to the BSD `date -j -v` form,
# and finally to 0 (= no cutoff). `2>/dev/null` hides the error from whichever form fails.
# 10 days ago in epoch for regular articles (wide window — deduplication via seen-file prevents repeats)
SINCE_EPOCH=$(date -d "10 days ago" +%s 2>/dev/null || date -j -v-10d +%s 2>/dev/null || echo 0)
# 60 days ago for release sources (announcements like model launches age slowly,
# but seen-deduplication still prevents repeats once surfaced)
RELEASE_SINCE_EPOCH=$(date -d "60 days ago" +%s 2>/dev/null || date -j -v-60d +%s 2>/dev/null || echo 0)

mkdir -p "$STATE_DIR"        # ensure the state dir exists (-p = no error if present)
echo "[]" > "$MERGE_FILE"    # seed the accumulator with an empty JSON array

log_info "started"

# --- [parse_feed] generic RSS/Atom feed parser (Python) ----------------------
# Downloads one feed URL and emits a JSON array of recent items. Works for both
# Atom (<entry>) and RSS (<item>) feeds. Args: url, source_name, source_domain, priority.
parse_feed() {
  local url="$1"            # `local` = these stay scoped to this function
  local source_name="$2"
  local source_domain="$3"
  local priority="$4"

  # curl flags: -s silent, -S still show errors, --max-time cap seconds,
  # -H sets a User-Agent header (some feeds reject blank UAs). `2>/dev/null` hides
  # curl's stderr. The downloaded XML is piped into an inline Python program
  # (`python3 -c "..."`). The bash $vars below ($source_name etc.) are interpolated
  # INTO the Python source before it runs, since the string is double-quoted.
  curl -sS --max-time "$FETCH_TIMEOUT" -H "User-Agent: morning-review/1.0" "$url" 2>/dev/null | python3 -c "
import sys, json, re, xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime
from datetime import datetime, timezone

source = '$source_name'
domain = '$source_domain'
priority = $priority
since = $SINCE_EPOCH

def find_or(el, tag1, tag2, ns):
    r = el.find(tag1, ns)
    if r is None:
        r = el.find(tag2, ns)
    return r

def parse_epoch(s):
    try:
        return int(datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp())
    except:
        pass
    try:
        return int(parsedate_to_datetime(s).timestamp())
    except:
        return 0

try:
    tree = ET.parse(sys.stdin)
    root = tree.getroot()
except:
    json.dump([], sys.stdout)
    sys.exit(0)

items = []
ns = {'atom': 'http://www.w3.org/2005/Atom'}

# Atom feeds
for entry in root.findall('.//atom:entry', ns):
    title_el = entry.find('atom:title', ns)
    link_el = entry.find('atom:link', ns)
    updated_el = find_or(entry, 'atom:updated', 'atom:published', ns)
    summary_el = find_or(entry, 'atom:summary', 'atom:content', ns)

    title = title_el.text.strip() if title_el is not None and title_el.text else ''
    url = link_el.get('href', '') if link_el is not None else ''
    description = re.sub('<[^>]+>', '', (summary_el.text if summary_el is not None and summary_el.text else '')[:500])
    published = updated_el.text if updated_el is not None else ''

    if title and url:
        epoch = parse_epoch(published)
        if epoch >= since:
            items.append({
                'title': title,
                'url': url,
                'published': published,
                'description': description[:300],
                'source': source,
                'source_domain': domain,
                'priority': priority
            })

# RSS feeds
for item in root.iter('item'):
    title_el = item.find('title')
    link_el = item.find('link')
    desc_el = item.find('description')
    pub_el = item.find('pubDate')

    title = title_el.text.strip() if title_el is not None and title_el.text else ''
    url = link_el.text.strip() if link_el is not None and link_el.text else ''
    description = re.sub('<[^>]+>', '', (desc_el.text if desc_el is not None and desc_el.text else '')[:500])
    published = pub_el.text if pub_el is not None else ''

    if title and url:
        epoch = parse_epoch(published)
        if epoch >= since:
            items.append({
                'title': title,
                'url': url,
                'published': published,
                'description': description[:300],
                'source': source,
                'source_domain': domain,
                'priority': priority
            })

json.dump(items[:20], sys.stdout)
" 2>/dev/null || echo "[]"
# ^ End of the inline Python. If anything fails, `|| echo "[]"` makes the
#   function still output a valid empty JSON array instead of nothing.
}

# --- [merge_feed] append one source's JSON into the running list -------------
# Safely merge feed results into MERGE_FILE
merge_feed() {
  local feed_json="$1"
  # Validate JSON: only proceed if the input parses as a JSON array.
  # `jq 'type == "array"'` returns true/false; we just care that it ran without error.
  if echo "$feed_json" | jq 'type == "array"' >/dev/null 2>&1; then
    local tmp
    tmp=$(mktemp)
    # Concatenate the two arrays: `-s` slurps all inputs into a list, then
    # `.[0] + .[1]` joins the existing accumulator (file) with the new feed.
    # `<(echo "$feed_json")` is process substitution: feeds the string to jq as a file.
    # Write to a temp file then `mv` over the accumulator (atomic, can't half-write).
    jq -s '.[0] + .[1]' "$MERGE_FILE" <(echo "$feed_json") > "$tmp" && mv "$tmp" "$MERGE_FILE"
  fi
}

# --- [fetch_hn] Hacker News via Algolia API ----------------------------------
fetch_hn() {
  local hn_json
  # Query Algolia's HN search API. The URL filters to stories matching the keywords,
  # created after $SINCE_EPOCH (%3E is a URL-encoded ">"), max 10 hits.
  # `|| echo '{"hits":[]}'` gives a valid empty response if curl fails.
  hn_json=$(curl -sS --max-time "$FETCH_TIMEOUT" \
    "https://hn.algolia.com/api/v1/search?query=claude+code+OR+agentic+coding+OR+ai+coding&tags=story&numericFilters=created_at_i%3E$SINCE_EPOCH&hitsPerPage=10" \
    2>/dev/null || echo '{"hits":[]}')

  # Reshape each Algolia hit into our common article schema.
  # `[.hits[] | {...}]` = for every element of .hits, build an object, collect into an array.
  echo "$hn_json" | jq '[.hits[] | {
    title: .title,
    url: (.url // ("https://news.ycombinator.com/item?id=" + (.objectID // ""))),   # `//` = use left, or right if left is null/missing (link to HN thread if no story URL)
    published: .created_at,
    description: (.story_text // "")[0:300],   # body text, truncated to 300 chars
    source: "hackernews",
    source_domain: "news.ycombinator.com",
    priority: 1
  }]' 2>/dev/null || echo "[]"
}

# --- [fetch_claude_code_releases] Claude Code GitHub releases (gh + jq) -------
# --- Claude Code GitHub releases (canonical source — docs.anthropic.com redirects here) ---
fetch_claude_code_releases() {
  # `command -v gh` checks the gh CLI exists; if not, output empty array and bail.
  # The `{ ...; }` groups two commands so both run when gh is missing.
  command -v gh >/dev/null 2>&1 || { echo "[]"; return; }

  # `gh api` calls the GitHub REST API and prints JSON. Pipe into jq to filter & reshape.
  # `--argjson since N` injects the epoch cutoff as a jq variable $since (numeric).
  gh api 'repos/anthropics/claude-code/releases?per_page=20' 2>/dev/null \
    | jq --argjson since "$RELEASE_SINCE_EPOCH" '
        [.[]                                          # for each release in the array
          | select(.published_at != null)            # skip drafts with no publish date
          | (.published_at | fromdateiso8601) as $epoch   # parse ISO date -> epoch, bind to $epoch
          | select($epoch >= $since)                  # keep only releases newer than the cutoff
          | {
              title: ("Claude Code " + (.tag_name // .name // "release")),   # prefer tag, then name, then "release"
              url: .html_url,
              published: .published_at,
              published_epoch: $epoch,
              description: ((.body // "") | gsub("\r"; "") | .[0:300]),   # strip CRs, truncate to 300 chars
              source: "github-claude-code",
              source_domain: "github.com/anthropics/claude-code",
              priority: 0,
              is_release: true
            }
        ]
        | sort_by(-.published_epoch)        # newest first (negative key = descending)
        | .[:5]                             # keep the 5 most recent
        | map(del(.published_epoch))        # drop the helper field we only needed for sorting
      ' 2>/dev/null || echo "[]"
}

# --- [fetch_anthropic_api_releases] platform.claude.com release notes (scrape)
# --- Anthropic API release notes (platform.claude.com — anchor-based scrape) ---
fetch_anthropic_api_releases() {
  local page_url="https://platform.claude.com/docs/en/release-notes/overview"

  # Download the HTML page (-L follows redirects) and scrape dated section anchors
  # with the inline Python below. There is no API/RSS, so we parse HTML directly.
  curl -sSL --max-time "$FETCH_TIMEOUT" -H "User-Agent: morning-review/1.0" "$page_url" 2>/dev/null | python3 -c "
import sys, re, json
from datetime import datetime, timezone

since = $RELEASE_SINCE_EPOCH
html = sys.stdin.read()

# Section anchors look like id=\"may-19-2026\" — one per dated release entry
anchors = re.findall(r'id=\"([a-z]+-\d{1,2}-20\d{2})\"', html)

seen = set()
results = []
for anchor_id in anchors:
    if anchor_id in seen:
        continue
    seen.add(anchor_id)
    parts = anchor_id.split('-')
    if len(parts) != 3:
        continue
    try:
        dt = datetime.strptime(f'{parts[0].title()} {parts[1]} {parts[2]}', '%B %d %Y')
    except ValueError:
        continue
    dt = dt.replace(tzinfo=timezone.utc)
    epoch = int(dt.timestamp())
    if epoch < since:
        continue
    pretty_date = dt.strftime('%b %-d, %Y')
    results.append({
        'title': f'Anthropic API release notes — {pretty_date}',
        'url': f'https://platform.claude.com/docs/en/release-notes/overview#{anchor_id}',
        'published': pretty_date,
        '_epoch': epoch,
        'description': '',
        'source': 'anthropic-api-releases',
        'source_domain': 'platform.claude.com',
        'priority': 0,
        'is_release': True
    })

results.sort(key=lambda r: r['_epoch'], reverse=True)
for r in results:
    del r['_epoch']
json.dump(results[:5], sys.stdout)
" 2>/dev/null || echo "[]"
}

# --- [fetch_anthropic_news] anthropic.com/news announcements (scrape) --------
# --- anthropic.com/news (Claude-related announcements, model launches) ---
fetch_anthropic_news() {
  # Download the news index HTML and scrape each <a href="/news/..."> block with Python.
  curl -sSL --max-time "$FETCH_TIMEOUT" -H "User-Agent: morning-review/1.0" 'https://www.anthropic.com/news' 2>/dev/null | python3 -c "
import sys, re, json
from datetime import datetime, timezone

since = $RELEASE_SINCE_EPOCH
html = sys.stdin.read()

# Each entry: <a href=\"/news/<slug>\" ...>...<time...>Mon DD, YYYY</time>...<h{2,4,6} ...>TITLE</h>...<p ...body...>DESC</p>...</a>
# Use a tolerant non-greedy regex over each anchor block.
results = []
seen = set()
for m in re.finditer(
    r'<a href=\"(/news/[a-z0-9-]+)\"[^>]*>(.*?)</a>',
    html, re.DOTALL
):
    slug, block = m.group(1), m.group(2)
    if slug in seen:
        continue
    seen.add(slug)

    date_m = re.search(r'<time[^>]*>\s*([A-Z][a-z]{2,9} \d{1,2},? 20\d{2})\s*</time>', block)
    title_m = re.search(r'<h[1-6][^>]*>\s*([^<][^<]{2,200}?)\s*</h[1-6]>', block)
    desc_m = re.search(r'<p[^>]*body[^>]*>\s*(.*?)\s*</p>', block, re.DOTALL)

    if not (date_m and title_m):
        continue
    date_str = date_m.group(1).replace(',', '')
    try:
        dt = datetime.strptime(date_str, '%b %d %Y')
    except ValueError:
        try:
            dt = datetime.strptime(date_str, '%B %d %Y')
        except ValueError:
            continue
    epoch = int(dt.replace(tzinfo=timezone.utc).timestamp())
    if epoch < since:
        continue

    title = re.sub(r'<[^>]+>', '', title_m.group(1)).strip()
    description = ''
    if desc_m:
        description = re.sub(r'<[^>]+>', '', desc_m.group(1)).strip()[:300]

    # Only include Claude-related news (matches user expectation of 'Claude / Claude Code releases')
    blob = (title + ' ' + description).lower()
    if 'claude' not in blob and 'opus' not in blob and 'sonnet' not in blob and 'haiku' not in blob:
        continue

    results.append({
        'title': title,
        'url': 'https://www.anthropic.com' + slug,
        'published': date_m.group(1),
        '_epoch': epoch,
        'description': description,
        'source': 'anthropic-news',
        'source_domain': 'anthropic.com/news',
        'priority': 0,
        'is_release': True
    })

results.sort(key=lambda r: r['_epoch'], reverse=True)
for r in results:
    del r['_epoch']
json.dump(results[:5], sys.stdout)
" 2>/dev/null || echo "[]"
}

# --- [fetch_anthropic] anthropic.com engineering/research blogs (scrape) -----
# --- Anthropic blog scraper (no RSS available) ---
fetch_anthropic() {
  local page_url="$1"
  local section="$2"   # "engineering" or "research" — selects which scrape logic the Python uses

  # Download the blog index and scrape article links/titles/dates with the inline Python.
  curl -sS --max-time "$FETCH_TIMEOUT" -H "User-Agent: morning-review/1.0" "$page_url" 2>/dev/null | python3 -c "
import sys, re, json
from datetime import datetime, timezone

section = '$section'
since = $SINCE_EPOCH
html = sys.stdin.read()
articles = []

if section == 'engineering':
    blocks = re.split(r'<article\b', html)
    for block in blocks[1:]:
        href = re.search(r'href=\"(/engineering/[a-z0-9-]+)\"', block)
        if not href:
            continue
        date_m = re.search(r'(\w{3} \d{1,2}, \d{4})', block)
        texts = [t.strip() for t in re.findall(r'>([^<]{5,})<', block) if t.strip()]
        title = None
        for t in texts:
            if any(s in t.lower() for s in ['illustration', 'abstract shapes', 'image for']):
                continue
            if re.match(r'\w{3} \d{1,2}, \d{4}', t):
                continue
            if len(t) > 10:
                title = t
                break
        if not title:
            title = href.group(1).split('/')[-1].replace('-', ' ').title()
        articles.append((href.group(1), title, date_m.group(1) if date_m else ''))

elif section == 'research':
    for m in re.finditer(
        r'href=\"(/research/[a-z0-9-]+)\"[^>]*>.*?<time[^>]*>([^<]+)</time>.*?title[^\"]*\">([^<]+)<',
        html, re.DOTALL
    ):
        articles.append((m.group(1), m.group(3).strip(), m.group(2).strip()))

results = []
for path, title, date_str in articles:
    epoch = 0
    if date_str:
        try:
            epoch = int(datetime.strptime(date_str, '%b %d, %Y').replace(tzinfo=timezone.utc).timestamp())
        except:
            pass
    if epoch >= since:
        results.append({
            'title': title,
            'url': 'https://www.anthropic.com' + path,
            'published': date_str,
            'description': '',
            'source': 'anthropic-' + section,
            'source_domain': 'anthropic.com',
            'priority': 1
        })

json.dump(results[:10], sys.stdout)
" 2>/dev/null || echo "[]"
}

# --- [fetch all sources] -----------------------------------------------------
# Each line runs one fetcher and pipes its JSON (captured via `$(...)`) into
# merge_feed, which appends it to MERGE_FILE. Priority (0 = highest) controls
# final ordering and which filters apply later.
# Claude / Claude Code release notes (priority 0) are pinned at the top of the
# morning-review article list and bypass keyword + exclusion filters below.

# A source runs only when enabled: ARTICLE_SOURCES (config key
# LOGBOOK_ARTICLE_SOURCES) is "all" or a comma-separated whitelist of the ids
# used below. install.sh offers this list as a picker on fresh installs.
source_enabled() {
  [ "${ARTICLE_SOURCES:-all}" = "all" ] && return 0
  case ",$ARTICLE_SOURCES," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

# Priority 0: Claude Code GitHub releases (canonical — docs.anthropic.com redirects here)
source_enabled claude-releases && merge_feed "$(fetch_claude_code_releases)"

# Priority 0: Anthropic API release notes (platform.claude.com)
source_enabled claude-api-releases && merge_feed "$(fetch_anthropic_api_releases)"

# Priority 0: anthropic.com/news (model launches, big announcements — Claude-filtered)
source_enabled anthropic-news && merge_feed "$(fetch_anthropic_news)"

# Priority 1: Anthropic Engineering Blog (HTML-scraped, no RSS)
source_enabled anthropic-engineering && merge_feed "$(fetch_anthropic "https://www.anthropic.com/engineering" "engineering")"

# Priority 1: Anthropic Research (HTML-scraped, no RSS)
source_enabled anthropic-research && merge_feed "$(fetch_anthropic "https://www.anthropic.com/research" "research")"

# Priority 1: Hacker News (pre-filtered by Algolia keyword query)
source_enabled hn && merge_feed "$(fetch_hn)"

# Priority 2: Addyo Substack (keyword-filtered below)
source_enabled addyo && merge_feed "$(parse_feed "https://addyo.substack.com/feed" "addyo" "addyo.substack.com" 2)"

# Priority 3: Simon Willison (keyword-filtered below)
source_enabled simonwillison && merge_feed "$(parse_feed "https://simonw.substack.com/feed" "simonwillison" "simonw.substack.com" 3)"

# Priority 4: Pragmatic Engineer (keyword-filtered below)
source_enabled pragmaticengineer && merge_feed "$(parse_feed "https://newsletter.pragmaticengineer.com/feed" "pragmaticengineer" "pragmaticengineer.com" 4)"

# Priority 4: Daniel Miessler (keyword-filtered below)
source_enabled danielmiessler && merge_feed "$(parse_feed "https://danielmiessler.com/feed.rss" "danielmiessler" "danielmiessler.com" 4)"

# Priority 5: r/ClaudeCode (noisy — quality-filtered below)
source_enabled r-claudecode && merge_feed "$(parse_feed "https://www.reddit.com/r/ClaudeCode/.rss" "r-claudecode" "reddit.com/r/ClaudeCode" 5)"

# --- [keyword filter] keep only AI-coding-relevant items ---------------------
# Keyword filter for non-HN sources. The `|`-separated string is a regex alternation
# (matches if ANY term appears). `--arg kw` passes it into jq as the string $kw.
KEYWORDS="agentic|ai coding|ai-assisted|llm|copilot|mcp server|model context protocol|prompt engineering|coding agent|ai pair programming|vibe coding|ai code review|ai workflow|ai architect|benchmark|deep dive|case study|best practices|reasoning model|chain of thought|tool use|function calling|rag |retrieval augmented|claude|ai agent|ai infrastructure|ci pipeline|ci failure|testing strategy|flaky test|migration guide|breaking change|software engineer|developer productivity|developer experience|code generation|code review|saas|ai rollout|tokenmaxx"

TMP=$(mktemp)
# For each item: priority 0-1 (releases/Anthropic) pass through untouched; everything
# else must match a keyword in its title+description (`test($kw; "i")`, "i" = case-insensitive)
# or it is dropped (`empty`). Result written to TMP, then moved over the accumulator.
jq --arg kw "$KEYWORDS" '[.[] |
  if .priority <= 1 then .
  else
    if ((.title + " " + (.description // "")) | test($kw; "i")) then .
    else empty end
  end
]' "$MERGE_FILE" > "$TMP" && mv "$TMP" "$MERGE_FILE"

# --- [exclude low-value] drop questions/anecdotes/announcements --------------
# --- Exclude low-value content (questions, anecdotes, gifts, announcements) ---
# Two regex blocklists: EXCLUDE_TITLE matches against the title only; EXCLUDE_COMBINED
# matches "this is just a release announcement" phrasing against title+description.
EXCLUDE_TITLE="looking for advice|help me|need help|any tips|recommend me|am i crazy|am i the only|unpopular opinion|hot take|what are the.*(pros|cons|difference)|coming from.*looking|gift card|giveaway|giving away|reduced my|changed my life|saved my|who else|does anyone|can someone|should i use|which is better|is this an error|is this a bug|worse than useless|now worse than|is anyone else bothered"
EXCLUDE_COMBINED="just released|new release|now available|changelog|release notes|patch notes|version [0-9]|v[0-9]+\\.[0-9]+.*released"

TMP=$(mktemp)
# Keep an item if it is a real release (is_release == true, exempt from exclusion),
# OR its title matches neither blocklist. `test(...) | not` = "does NOT match".
# `and` requires both blocklists to miss before a non-release item is kept.
jq --arg ext "$EXCLUDE_TITLE" --arg exc "$EXCLUDE_COMBINED" '[.[] |
  select(
    (.is_release == true) or
    (
      (.title | test($ext; "i") | not) and
      ((.title + " " + (.description // "")) | test($exc; "i") | not)
    )
  )
]' "$MERGE_FILE" > "$TMP" && mv "$TMP" "$MERGE_FILE"

# --- [reddit quality filter] extra-strict bar for noisy Reddit source --------
# --- Quality filter for Reddit: stricter bar (kills memes/questions/image posts) ---
# Requires 300+ char description AND at least one keyword match
TMP=$(mktemp)
# Only priority >= 5 (Reddit) gets the strict treatment; everything else passes through.
jq --arg kw "$KEYWORDS" '[.[] |
  if .priority >= 5 then
    select(.title | test("\\?\\s*$") | not) |   # drop titles ending in "?" (questions)
    # Clean the description with a chain of `gsub` (regex search-and-replace) steps,
    # then bind the cleaned text to $clean for the two checks that follow:
    ((.description // "")
      | gsub("&#[0-9]+;"; " ")                       # decode numeric HTML entities -> space
      | gsub("&[a-z]+;"; " ")                         # decode named HTML entities (&amp; etc.) -> space
      | gsub("submitted by\\s+/u/[^\\s]+[\\s]*"; "")  # strip Reddit "submitted by /u/name" boilerplate
      | gsub("\\[link\\]|\\[comments\\]"; "")         # strip Reddit "[link] [comments]" footer
      | gsub("<[^>]*>"; "")                            # strip complete HTML tags
      | gsub("<[^>]*$"; "")                            # strip a trailing truncated/unclosed tag
      | gsub("\\s+"; " ")                              # collapse runs of whitespace to one space
      | gsub("^ +| +$"; "")                            # trim leading/trailing spaces
    ) as $clean |
    select(($clean | length) >= 300) |                # require a substantial body (>=300 chars)
    select((.title + " " + $clean) | test($kw; "i"))  # and at least one keyword match
  else .
  end
]' "$MERGE_FILE" > "$TMP" && mv "$TMP" "$MERGE_FILE"

# --- [dedupe / sort / write] final cleanup and write the cache file ----------
# --- Deduplicate by URL ---
TMP=$(mktemp)
# `group_by(.url)` buckets items sharing a URL; `[] | .[0]` takes the first of each bucket.
jq '[group_by(.url)[] | .[0]]' "$MERGE_FILE" > "$TMP" && mv "$TMP" "$MERGE_FILE"

# --- Sort by priority then recency ---
TMP=$(mktemp)
# `sort_by(.priority)` orders ascending, so priority 0 (releases) ends up first.
jq 'sort_by(.priority)' "$MERGE_FILE" > "$TMP" && mv "$TMP" "$MERGE_FILE"

# --- Write cache ---
FETCHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")   # UTC timestamp recorded in the cache
ARTICLE_COUNT=$(jq 'length' "$MERGE_FILE")    # count items for the log line below
# `jq -n` builds JSON from scratch (no input). `--arg ts` injects the timestamp string;
# `--slurpfile articles FILE` reads the whole file as a JSON array bound to $articles
# (wrapped in an outer array, hence `$articles[0]` to get the array itself).
jq -n --arg ts "$FETCHED_AT" --slurpfile articles "$MERGE_FILE" '{
  fetched_at: $ts,
  articles: $articles[0]
}' > "$CACHE_FILE"

log_info "done — ${ARTICLE_COUNT} articles cached"

exit 0
