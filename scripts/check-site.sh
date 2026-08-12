#!/bin/bash
# GitHub Pages site integrity check for site/.
#
# What check.sh already does for the site is *formatting* — prettier owns the
# html/css layout, xmllint owns the sitemap's well-formedness. Neither one looks
# at whether the page it just formatted actually works once deployed:
# `.github/workflows/pages.yml` uploads site/ verbatim with no build step, so a
# renamed asset, a stale absolute URL, or a missing CNAME is not a build error
# anywhere — it is a 404 (or an unbound custom domain) on the live site, and the
# repo stays green the whole time. Prettier reformats a broken `src=` as happily
# as a working one.
#
# So this script checks the things that decide whether site/ *deploys correctly*:
#
#   1. the files GitHub Pages needs are present;
#   2. every local reference in the html/css resolves to a file that exists;
#   3. every in-page `#fragment` link has a matching id;
#   4. every absolute https://<domain>/ URL — canonical, og:image, JSON-LD,
#      sitemap, robots — names the domain in CNAME and resolves to a real file;
#   5. nothing under assets/ is shipped without being referenced.
#
# Deliberately offline: external links (github.com, assemblyai.com, Google
# Fonts) are NOT fetched. check.sh must be deterministic and runnable with no
# network, and a third party's outage is not this repo being broken. Pure text
# and filesystem work, so it runs in `check.sh --portable` too.
#
# Run standalone while editing the site:  bash scripts/check-site.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="$REPO_ROOT/site"

VIOLATION=0

# Report a problem and mark the run failed. Every check below keeps going after
# a failure so one run lists everything wrong with the site, rather than making
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
# Each of these is load-bearing for the deployed site, and each is invisible
# when missing until someone visits: no CNAME and the custom domain unbinds (the
# site falls back to the github.io path and every absolute URL below breaks); no
# index.html and the root 404s; no robots/sitemap and the SEO surface goes away.
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
# Escaped for use inside the grep -E patterns further down.
DOMAIN_RE="$(printf '%s' "$DOMAIN" | sed 's/[.[\*^$]/\\&/g')"

HTML_FILES="$(find . -type f -name '*.html' | sed 's|^\./||' | sort)"
[ -n "$HTML_FILES" ] || fail "site/ contains no .html files"

# --- 2. local references resolve --------------------------------------------
# Resolve one reference taken from $2 (the file it appeared in) and complain if
# it does not exist. Off-site schemes are skipped — see the offline note above.
check_local_ref() {
  local ref="$1" from="$2" base target

  case "$ref" in
    http://* | https://* | //* | mailto:* | tel:* | data:* | '') return 0 ;;
    '#'*) return 0 ;; # fragment-only links are handled in section 3
  esac

  # Drop the query and fragment: `styles.css?v=2#x` is still styles.css on disk.
  ref="${ref%%\#*}"
  ref="${ref%%\?*}"
  [ -n "$ref" ] || return 0

  case "$ref" in
    /*) target="${ref#/}" ;; # root-relative: relative to site/
    *)
      base="$(dirname "$from")"
      if [ "$base" = "." ]; then target="$ref"; else target="$base/$ref"; fi
      ;;
  esac

  # A directory URL (including the bare "/") serves that directory's index.html.
  if [ -z "$target" ] || [ -d "$target" ]; then
    target="${target:+$target/}index.html"
  fi

  [ -e "$target" ] || fail "$from references '$1', but site/$target does not exist"
}

echo "==> site: local references"
while IFS= read -r html; do
  # src/href/poster carry one URL; srcset carries a comma-separated candidate
  # list where each entry is "<url> <descriptor>" — so split on commas and keep
  # the first token. Attribute values never span lines in prettier's output, so
  # a line-oriented grep is enough here (the tag-level extraction in section 4,
  # which does have to cope with wrapped tags, flattens the file first).
  while IFS= read -r attr; do
    value="${attr#*=\"}"
    value="${value%\"}"
    case "$attr" in
      srcset=*)
        printf '%s\n' "$value" | tr ',' '\n' | while IFS= read -r candidate; do
          # shellcheck disable=SC2086 # deliberate split: "<url> <descriptor>"
          set -- $candidate
          [ "$#" -gt 0 ] && check_local_ref "$1" "$html"
        done
        ;;
      *) check_local_ref "$value" "$html" ;;
    esac
  done < <(grep -oE '(src|href|poster|srcset)="[^"]*"' "$html" || true)
done <<<"$HTML_FILES"

# CSS url(...) references. None today — the site's imagery all lives in the
# html — but a background-image added later would otherwise ship unchecked.
while IFS= read -r css; do
  [ -n "$css" ] || continue
  while IFS= read -r raw; do
    value="${raw#url(}"
    value="${value%)}"
    value="${value#[\"\']}"
    value="${value%[\"\']}"
    check_local_ref "$value" "$css"
  done < <(grep -oE 'url\([^)]*\)' "$css" || true)
done < <(find . -type f -name '*.css' | sed 's|^\./||' | sort)

# --- 3. in-page fragments ----------------------------------------------------
# `href="#features"` with no `id="features"` is a nav link that scrolls nowhere.
# Silent in every linter and in the browser console alike.
echo "==> site: in-page anchors"
while IFS= read -r html; do
  while IFS= read -r frag; do
    [ -n "$frag" ] || continue
    grep -qE "id=\"$frag\"" "$html" \
      || fail "$html links to '#$frag', but no element in it has id=\"$frag\""
  done < <(grep -oE 'href="#[^"]+"' "$html" | sed 's/^href="#//;s/"$//' | sort -u || true)
done <<<"$HTML_FILES"

# --- 4. absolute self-URLs ---------------------------------------------------
# Everything the site says about itself to a machine — the canonical link, the
# Open Graph card, the JSON-LD, the sitemap, robots.txt — is an absolute URL, so
# each one is a copy of the domain that CNAME owns. Change the domain and they
# all go stale at once, pointing search engines and social-card scrapers at a
# host this repo no longer serves. Nothing else in the repo compares them.
echo "==> site: absolute URLs (domain $DOMAIN)"

# Every https://<domain>/… in the site must resolve to a file we actually ship.
# This is what catches the og:image and JSON-LD image paths, which are written
# absolutely and so are invisible to the relative-reference pass above.
while IFS= read -r url; do
  [ -n "$url" ] || continue
  # $DOMAIN quoted inside the expansion: unquoted it would be read as a glob.
  path="${url#https://"$DOMAIN"}"
  path="${path#/}"
  path="${path%%\#*}"
  path="${path%%\?*}"
  if [ -z "$path" ] || [ -d "$path" ]; then
    path="${path:+$path/}index.html"
  fi
  [ -e "$path" ] || fail "$url is served by this site, but site/$path does not exist"
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

CANONICAL="$(tag_value '<link[^>]*rel="canonical"[^>]*>' href || true)"
OG_URL="$(tag_value '<meta[^>]*property="og:url"[^>]*>' content || true)"

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

check_self_url "canonical link" "$CANONICAL"
check_self_url "og:url" "$OG_URL"

# robots.txt must point crawlers at this domain's sitemap, not a previous one.
ROBOTS_SITEMAP="$(grep -iE '^[[:space:]]*Sitemap:' robots.txt | head -1 | sed 's/^[[:space:]]*[Ss]itemap:[[:space:]]*//' | tr -d '[:space:]' || true)"
if [ -z "$ROBOTS_SITEMAP" ]; then
  fail "robots.txt declares no Sitemap:"
elif [ "$ROBOTS_SITEMAP" != "https://$DOMAIN/sitemap.xml" ]; then
  fail "robots.txt points at '$ROBOTS_SITEMAP', but CNAME says https://$DOMAIN/sitemap.xml"
fi

# Every <loc> must be on this domain. (xmllint already proved the file parses;
# that says nothing about where the URLs point.) The existence of each one is
# covered by the https://<domain>/ sweep above.
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

# --- 5. no orphaned assets ---------------------------------------------------
# The Pages artifact is whatever is in site/, so an asset no page references is
# still uploaded and served — dead weight in the deploy, and usually the trace
# of a rename where the old file was left behind. Same rule the sound-catalog
# guard in check.sh applies to the cue audio.
#
# Matched as the site-relative path ("assets/icon.png"), which finds both the
# relative `src=` form and the absolute https://<domain>/assets/… form, and
# can't be fooled by a longer filename that ends the same way
# ("assets/blurt-b-icon.png" does not contain the string "assets/icon.png").
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
