#!/bin/bash
# GitHub Pages site integrity check for site/.
#
# `.github/workflows/pages.yml` uploads site/ verbatim with no build step, so a
# renamed asset, a stale absolute URL, or a missing CNAME is not a build error
# anywhere — it is a 404 (or an unbound custom domain) on the live site, and the
# repo stays green the whole time. prettier and xmllint in check.sh cover the
# site's *formatting* and the sitemap's well-formedness; prettier reformats a
# broken src= as happily as a working one.
#
# Two halves, split along what a general tool can know:
#
#   html-proofer  — links, images (including <source srcset>), scripts, favicon,
#                   in-page #fragments and Open Graph. Its defaults also flag a
#                   missing alt, an <a> without href, and an empty src, so those
#                   come along free. A mature checker parses HTML properly;
#                   doing that with grep is the part most likely to rot.
#   this script   — the repo-level invariants no HTML checker models: that CNAME
#                   and every absolute URL agree, that the sitemap and robots
#                   point at this domain, and that nothing under assets/ ships
#                   unreferenced. Plus CSS url(), which html-proofer never reads
#                   because it only looks at HTML, and the two HTML gaps in
#                   section 4 that its checks were measured not to cover.
#
# Every check html-proofer offers is enabled: the five check classes it has
# (Links, Images, Scripts, Favicon, OpenGraph) and its stricter defaults, none
# of which are switched off here. --check-sri is the one deliberate omission —
# it is a no-op under --disable-external, and the single external subresource
# this site has is the Google Fonts stylesheet, which is served per-user-agent
# and so cannot carry a fixed integrity hash.
#
# The domain is read from site/CNAME once and handed to html-proofer as its
# --swap-urls pattern. That matters: og:image and friends are absolute URLs, so
# html-proofer skips them as external unless told that https://<domain>/ IS this
# directory. Writing that domain into a config file would be a second place it
# is recorded and the exact drift section 3 exists to catch — deriving it from
# CNAME keeps one source of truth.
#
# Deliberately offline: external links (github.com, assemblyai.com, Google
# Fonts) are NOT fetched, hence --disable-external. check.sh must be
# deterministic and runnable with no network, and a third party's outage is not
# this repo being broken. Note this is also why external checking cannot stand
# in for the local og:image check: with --disable-external off, html-proofer
# fetches the *currently deployed* card rather than the one about to ship, so a
# deleted local file passes.
#
# Run standalone while editing the site:  bash scripts/check-site.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="$REPO_ROOT/site"

VIOLATION=0

# Report a problem and mark the run failed. Every check keeps going after a
# failure so one run lists everything wrong with the site, rather than making
# the author fix-and-rerun once per broken link.
fail() {
  echo "error: $*" >&2
  VIOLATION=1
}

[ -d "$SITE" ] || {
  echo "error: no site/ directory at $SITE" >&2
  exit 1
}

cd "$SITE"

# --- 1. required files -------------------------------------------------------
# Each is load-bearing for the deployed site and invisible when missing until
# someone visits: no CNAME and the custom domain unbinds (the site falls back to
# the github.io path and every absolute URL below breaks); no index.html and the
# root 404s; no robots/sitemap and the SEO surface goes away.
for required in index.html CNAME robots.txt sitemap.xml; do
  [ -f "$required" ] || fail "site/$required is missing — the Pages deploy needs it"
done

[ -f CNAME ] || {
  echo "error: cannot continue without site/CNAME" >&2
  exit 1
}

# The custom domain, and the single source of truth for every absolute URL in
# the site. `tr -d` rather than a plain read: a stray CR or trailing newline in
# CNAME is invisible in a diff and would silently break every comparison below.
DOMAIN="$(tr -d '[:space:]' <CNAME)"
[ -n "$DOMAIN" ] || {
  echo "error: site/CNAME is empty" >&2
  exit 1
}
# Dots escaped, for the grep -E and html-proofer regexes further down.
DOMAIN_RE="$(printf '%s' "$DOMAIN" | sed 's/\./\\./g')"

HTML_FILES="$(find . -type f -name '*.html' | sed 's|^\./||' | sort)"
[ -n "$HTML_FILES" ] || fail "site/ contains no .html files"

# --- 2. html-proofer ---------------------------------------------------------
# Links, images, srcset, scripts, favicon, in-page #fragments and Open Graph.
if command -v htmlproofer >/dev/null 2>&1; then
  echo "==> site: html-proofer"

  # LANG/LC_ALL pinned, and not decoratively. Run under a non-UTF-8 locale,
  # html-proofer dies inside Nokogiri on this page's em-dashes, checks zero
  # links, prints "finished successfully" and exits 0 — a gate that passes
  # because it never ran. The output assertion below is the belt to this
  # braces: neither alone is enough.
  #
  # --swap-urls tells html-proofer that https://<domain>/ is this directory, so
  # the absolute og:image / JSON-LD / canonical URLs resolve against site/
  # instead of being skipped as external. Colons inside the pattern are
  # \-escaped because html-proofer splits the argument on ':'.
  HP_OUT=""
  HP_STATUS=0
  HP_OUT="$(
    LANG=C.UTF-8 LC_ALL=C.UTF-8 htmlproofer . \
      --disable-external \
      --checks Links,Images,Scripts,Favicon,OpenGraph \
      --root-dir . \
      --swap-urls "^https\\://$DOMAIN_RE/:/" 2>&1
  )" || HP_STATUS=$?

  # Drop html-proofer's structured async log lines; they are noise here.
  printf '%s\n' "$HP_OUT" | grep -vE '^\{"time' | grep -vE '^\s*$' || true

  if [ "$HP_STATUS" -ne 0 ]; then
    fail "html-proofer found problems in the site (above)"
  fi

  # Did it actually check anything? See the locale note above — this is the
  # guard that turns a silent no-op into a failure. check.sh's coverage gate
  # learned the same lesson (a missing profile used to print a note and exit 0).
  HP_LINKS="$(printf '%s\n' "$HP_OUT" | sed -n 's/^Checking \([0-9][0-9]*\) internal links.*/\1/p' | head -1)"
  if [ -z "${HP_LINKS:-}" ] || [ "$HP_LINKS" -eq 0 ]; then
    fail "html-proofer checked 0 internal links — it did not actually run (locale? parse error?)"
  fi
else
  echo "note: htmlproofer not installed; skipping link/image/og checks (gem install html-proofer)"
  echo "      the CNAME, sitemap, CSS and orphan checks below still run"
fi

# --- 3. absolute self-URLs ---------------------------------------------------
# Everything the site says about itself to a machine — canonical, Open Graph,
# JSON-LD, sitemap, robots — is an absolute URL, so each is a copy of the domain
# CNAME owns. Change the domain and they all go stale at once, pointing search
# engines and social-card scrapers at a host this repo no longer serves.
#
# html-proofer covers the HTML ones now (via --swap-urls above) but only for
# *existence*, and only inside HTML. It has no opinion on whether the domain is
# the right one, and it never reads sitemap.xml or robots.txt, which are not
# HTML. Both gaps are this section.
echo "==> site: absolute URLs (domain $DOMAIN)"

# Resolve a site-relative path and complain if it does not exist.
site_path_exists() {
  local path="$1"
  path="${path%%\#*}"
  path="${path%%\?*}"
  path="${path#/}"
  if [ -z "$path" ] || [ -d "$path" ]; then
    path="${path:+$path/}index.html"
  fi
  [ -e "$path" ]
}

# Every https://<domain>/… in the non-HTML files must resolve to something we
# ship. (The HTML ones are html-proofer's; sweeping them here too costs nothing
# and keeps the check meaningful when html-proofer is absent.)
while IFS= read -r url; do
  [ -n "$url" ] || continue
  # $DOMAIN quoted inside the expansion: unquoted it would be read as a glob.
  site_path_exists "${url#https://"$DOMAIN"}" \
    || fail "$url is served by this site, but no such file exists under site/"
done < <(grep -rhoE "https://$DOMAIN_RE(/[^\"'[:space:]<>)]*)?" \
  --include='*.html' --include='*.css' --include='*.xml' --include='*.txt' . \
  | sort -u || true)

# Flattened so a prettier-wrapped multi-line <meta>/<link> still matches.
FLAT="$(tr '\n' ' ' <index.html)"

# Pull the value of $2 (href/content) out of the first tag matching $1.
tag_value() {
  printf '%s' "$FLAT" | grep -oE "$1" | head -1 \
    | grep -oE "$2=\"[^\"]*\"" | head -1 | sed "s/^$2=\"//;s/\"$//"
}

# Both must name the site's own root. A canonical or og:url on a stale domain
# splits the page's search identity and makes shared links resolve elsewhere.
check_self_url() {
  local label="$1" value="$2"
  if [ -z "$value" ]; then
    fail "index.html has no $label — search engines and social cards need it"
  elif [ "$value" != "https://$DOMAIN/" ]; then
    fail "index.html $label is '$value', but CNAME says the site is https://$DOMAIN/"
  fi
}

check_self_url "canonical link" "$(tag_value '<link[^>]*rel="canonical"[^>]*>' href || true)"
check_self_url "og:url" "$(tag_value '<meta[^>]*property="og:url"[^>]*>' content || true)"

# robots.txt must point crawlers at this domain's sitemap, not a previous one.
ROBOTS_SITEMAP="$(grep -iE '^[[:space:]]*Sitemap:' robots.txt | head -1 | sed 's/^[[:space:]]*[Ss]itemap:[[:space:]]*//' | tr -d '[:space:]' || true)"
if [ -z "$ROBOTS_SITEMAP" ]; then
  fail "robots.txt declares no Sitemap:"
elif [ "$ROBOTS_SITEMAP" != "https://$DOMAIN/sitemap.xml" ]; then
  fail "robots.txt points at '$ROBOTS_SITEMAP', but CNAME says https://$DOMAIN/sitemap.xml"
fi

# Every <loc> must be on this domain. (xmllint already proved the file parses;
# that says nothing about where the URLs point, and no HTML checker reads it.)
SITEMAP_LOCS="$(grep -oE '<loc>[^<]*</loc>' sitemap.xml | sed 's|</\?loc>||g' || true)"
if [ -z "$SITEMAP_LOCS" ]; then
  fail "sitemap.xml lists no <loc> entries"
else
  while IFS= read -r loc; do
    case "$loc" in
      "https://$DOMAIN/"*) ;;
      *) fail "sitemap.xml lists '$loc', which is not on https://$DOMAIN/" ;;
    esac
  done <<<"$SITEMAP_LOCS"
fi

# --- 4. HTML hygiene ---------------------------------------------------------
# Two things html-proofer's defaults leave uncovered. Both were found by testing
# its checks one at a time rather than assuming the tool's coverage.
echo "==> site: HTML hygiene"
while IFS= read -r html; do
  # Duplicate id. html-proofer 5 dropped the HTML validation v3 had, so nothing
  # flags this — and it defeats the very check it does run: an ambiguous
  # `#features` resolves to the first match, so the internal-hash check passes
  # while the page is malformed and the browser's target is a coin flip.
  DUPE_IDS="$(grep -oE 'id="[^"]+"' "$html" | sed 's/^id="//;s/"$//' | sort | uniq -d || true)"
  if [ -n "$DUPE_IDS" ]; then
    while IFS= read -r dupe; do
      fail "$html has more than one element with id=\"$dupe\" — #$dupe targets whichever comes first"
    done <<<"$DUPE_IDS"
  fi

  # Insecure references. html-proofer's enforce_https defaults on, but it only
  # inspects links it is fetching, so under --disable-external (which this repo
  # requires, see the header) it never fires — verified by adding an http:// link
  # and watching it pass. Scoped to attribute values so an XML/XHTML namespace,
  # which is an identifier rather than a fetchable URL, isn't a false positive.
  INSECURE="$(grep -oE '(href|src|srcset|content|poster)="http://[^"]*"' "$html" || true)"
  if [ -n "$INSECURE" ]; then
    while IFS= read -r ref; do
      fail "$html references $ref over plain http — the site is https-only"
    done <<<"$INSECURE"
  fi
done <<<"$HTML_FILES"

# --- 5. CSS url() ------------------------------------------------------------
# html-proofer only reads HTML, so a background-image added to styles.css would
# otherwise ship unchecked. None today — the site's imagery all lives in the
# markup — which is exactly when a guard is cheap to add.
echo "==> site: CSS references"
while IFS= read -r css; do
  [ -n "$css" ] || continue
  while IFS= read -r raw; do
    value="${raw#url(}"
    value="${value%)}"
    value="${value#[\"\']}"
    value="${value%[\"\']}"
    case "$value" in
      http://* | https://* | //* | data:* | '') continue ;;
    esac
    # Relative to the stylesheet, unless rooted at the site.
    case "$value" in
      /*) target="$value" ;;
      *)
        base="$(dirname "$css")"
        if [ "$base" = "." ]; then target="$value"; else target="$base/$value"; fi
        ;;
    esac
    site_path_exists "$target" || fail "$css references '$value', but no such file exists under site/"
  done < <(grep -oE 'url\([^)]*\)' "$css" || true)
done < <(find . -type f -name '*.css' | sed 's|^\./||' | sort)

# --- 6. no orphaned assets ---------------------------------------------------
# The Pages artifact is whatever is in site/, so an asset no page references is
# still uploaded and served — dead weight in the deploy, and usually the trace
# of a rename where the old file was left behind. Link checkers walk references
# to files; this is the other direction, which none of them do.
#
# Matched as the site-relative path ("assets/icon.png"), which finds both the
# relative src= form and the absolute https://<domain>/assets/… form, and can't
# be fooled by a longer filename ending the same way ("assets/blurt-b-icon.png"
# does not contain the string "assets/icon.png").
echo "==> site: asset references"
if [ -d assets ]; then
  while IFS= read -r asset; do
    [ -n "$asset" ] || continue
    grep -rqF "$asset" \
      --include='*.html' --include='*.css' --include='*.xml' --include='*.txt' . \
      || fail "site/$asset is referenced by nothing — it ships in the Pages artifact unused"
  done < <(find assets -type f | sed 's|^\./||' | sort)
fi

[ "$VIOLATION" -eq 0 ] || exit 1

echo "site ok: $(printf '%s\n' "$HTML_FILES" | wc -l | tr -d ' ') page(s) on $DOMAIN, all references resolve"
