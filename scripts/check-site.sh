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
# No dependencies, by design and by measurement. This started bespoke, moved to
# html-proofer to get a real HTML parser, and moved back when Aikido flagged the
# licence on `ttfunk` — GPL-2.0-only / GPL-3.0-only, reached via
# html-proofer -> pdf-reader -> ttfunk. Bundler cannot drop a transitive gem, so
# keeping the parser meant keeping a GPL branch in an MIT repo's lockfile, and
# 20 gems of supply-chain surface for a one-page static site.
#
# Nothing was lost in the move back. The html-proofer audit is what surfaced the
# four checks in section 5 (missing alt, <a> without href, empty src, and the
# favicon, which section 2 covers as an ordinary href) — they are kept here as
# greps. What went with it was its baggage: a Gemfile, bundler in CI, a pinned
# locale to stop Nokogiri dying on this page's em-dashes, a --swap-urls hack to
# convince it that https://<domain>/ was the directory it was already reading,
# and a guard asserting it had actually run.
#
# Deliberately offline: external links (github.com, assemblyai.com, Google
# Fonts) are NOT fetched. check.sh must be deterministic and runnable with no
# network, and a third party's outage is not this repo being broken. It is also
# why a fetching checker cannot cover og:image: it would test the *currently
# deployed* card rather than the one about to ship, so a deleted local file
# would pass.
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
        # Process substitution, NOT `printf ... | while`: a pipeline runs its
        # right-hand side in a subshell, so `fail`'s VIOLATION=1 would be set in
        # that subshell and lost. This exact bug shipped once — a broken srcset
        # printed `error:` and the script still exited 0, a gate that reports a
        # failure and passes anyway. Keep the loop in the parent shell.
        while IFS= read -r candidate; do
          # shellcheck disable=SC2086 # deliberate split: "<url> <descriptor>"
          set -- $candidate
          [ "$#" -gt 0 ] && check_local_ref "$1" "$html"
        done < <(printf '%s\n' "$value" | tr ',' '\n')
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
# Two explicit expressions rather than one `</\?loc>`: `\?` is a GNU sed
# extension, so on macOS's BSD sed it matches a literal '?', the tags survive
# the strip, and every <loc> then fails the comparison below against a domain it
# actually matches. That is precisely how this first reached CI — green on Linux,
# red on macos-26 — so keep anything here to POSIX BRE/ERE.
SITEMAP_LOCS="$(grep -oE '<loc>[^<]*</loc>' sitemap.xml | sed -e 's|.*<loc>||' -e 's|</loc>.*||' || true)"
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

# --- 5. HTML hygiene ---------------------------------------------------------
# The per-element checks. The first two came from auditing what html-proofer
# left uncovered; the rest are the ones it did cover, kept as greps when it went
# (see the header) so the move back cost no coverage. Line-oriented parsing is
# safe here because check.sh runs `prettier --check` over site/*.html, so the
# one-attribute-per-line shape these assume is itself gated.
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

  # Insecure references. Scoped to attribute values so an XML/XHTML namespace,
  # which is an identifier rather than a fetchable URL, isn't a false positive.
  # (html-proofer had enforce_https on by default but only inspected links it was
  # fetching, so with external checking off it never fired — measured, not
  # assumed. Nothing was covering this even while the tool was here.)
  INSECURE="$(grep -oE '(href|src|srcset|content|poster)="http://[^"]*"' "$html" || true)"
  if [ -n "$INSECURE" ]; then
    while IFS= read -r ref; do
      fail "$html references $ref over plain http — the site is https-only"
    done <<<"$INSECURE"
  fi

  # An <img> with no alt at all is unreadable to a screen reader. An empty
  # alt="" is fine and deliberate — it marks an image as decorative, which is
  # what the brand logo beside the "Blurt" wordmark is — so only a *missing*
  # attribute is a failure, matching html-proofer's ignore_empty_alt default.
  # Flattened per-tag, since prettier wraps a multi-attribute <img> across lines.
  MISSING_ALT="$(tr '\n' ' ' <"$html" | grep -oE '<img[^>]*>' | grep -vE '[[:space:]]alt=' || true)"
  if [ -n "$MISSING_ALT" ]; then
    while IFS= read -r img; do
      fail "$html has an <img> with no alt attribute: $(printf '%s' "$img" | cut -c1-70)"
    done <<<"$MISSING_ALT"
  fi

  # An <a> with no href is not a link — it renders as inert text, silently.
  NO_HREF="$(tr '\n' ' ' <"$html" | grep -oE '<a[[:space:]][^>]*>|<a>' | grep -vE '[[:space:]]href=' || true)"
  if [ -n "$NO_HREF" ]; then
    while IFS= read -r anchor; do
      fail "$html has an <a> with no href: $(printf '%s' "$anchor" | cut -c1-70)"
    done <<<"$NO_HREF"
  fi

  # An empty src=""/href="" resolves to the page itself: a browser re-requests
  # the document, so a blank <img src=""> silently downloads the HTML again.
  EMPTY_REF="$(grep -oE '(src|href)=""' "$html" || true)"
  if [ -n "$EMPTY_REF" ]; then
    fail "$html has an empty $(printf '%s' "$EMPTY_REF" | head -1) — it re-requests the page itself"
  fi
done <<<"$HTML_FILES"

# --- 6. CSS url() -----------------------------------------------------------
# Stylesheets are not HTML, so nothing above reads them. None today — the site's
# imagery all lives in the markup — which is exactly when a guard is cheap.
echo "==> site: CSS references"
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

# --- 7. no orphaned assets ---------------------------------------------------
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
