#!/bin/bash
# Records the exact prompts used to generate Blurt's README/logo branding in
# Codex. This is a provenance script, not a local renderer.
#
# Generated assets currently in the repo:
#   - .github/images/blurt-logo-ansi.png
#   - App/Blurt/Blurt/Branding/blurt-ready-logo.png
#   - App/Blurt/Blurt/AppIcon.icon/Assets/blurt-mic-glyph.png
#
# The images were originally created with Codex's image generation tool, then
# lightly processed locally with ImageMagick:
#   - the README wordmark was trimmed tighter
#   - the ready-screen wordmark was derived from the README mark with slightly
#     calmer saturation
#   - the Dock icon was regenerated separately as a dark-tile icon
#
# Keep the prompts here so the assets can be regenerated consistently when the
# branding changes.

set -euo pipefail

readme_logo_prompt() {
  cat <<'EOF'
Create a wide transparent-background logo image that says "BLURT" in classic
TheDraw ANSI art / BBS scene style. Use chunky DOS-era ANSI block lettering,
crisp pixel edges, terminal-style shading, and a restrained cyan-magenta-white
palette on transparency. It should feel like authentic 1990s bulletin board
ANSI title art, centered, readable, and suitable for placement at the top of a
GitHub README. No extra objects, no mock terminal window, no background scene,
just the standalone logo art.
EOF
}

app_icon_prompt() {
  cat <<'EOF'
Create a macOS app icon, 1024x1024, for an app called BLURT. The icon should
feature a single capital letter B in a retro ANSI / TheDraw / BBS-inspired
pixel style, but simplified and cleaner than a banner logo. Use a dark rounded-
square background tile, with the B centered and highly legible at small Dock
sizes. Keep the cyan-magenta-white palette, but reduce internal dithering/noise
so the silhouette reads instantly. Crisp pixel edges, restrained shading,
strong contrast, no mic shape, no extra symbols, no checkerboard, no
transparent background required.
EOF
}

usage() {
  cat <<'EOF'
Usage:
  scripts/generate-branding-images.sh readme-logo
  scripts/generate-branding-images.sh app-icon
  scripts/generate-branding-images.sh all

This script prints the exact prompts used for the current branding assets.
Regenerate the images with Codex image generation (or another image tool),
then save/process them to:
  .github/images/blurt-logo-ansi.png
  App/Blurt/Blurt/Branding/blurt-ready-logo.png
  App/Blurt/Blurt/AppIcon.icon/Assets/blurt-mic-glyph.png
EOF
}

case "${1:-}" in
  readme-logo)
    readme_logo_prompt
    ;;
  app-icon)
    app_icon_prompt
    ;;
  all)
    echo "README logo prompt:"
    echo
    readme_logo_prompt
    echo
    echo "App icon prompt:"
    echo
    app_icon_prompt
    ;;
  *)
    usage
    exit 1
    ;;
esac
