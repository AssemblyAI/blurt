# Ruby-managed check.sh tools. Brewfile is the source of truth for everything
# Homebrew can install; this file exists for the one tool it can't — html-proofer
# ships only as a gem, and scripts/check-site.sh uses it for the Pages site's
# links, images, srcset, favicon and Open Graph.
#
# A lockfile rather than a bare `gem install` for two reasons. It pins the whole
# transitive set (20-odd gems, Nokogiri among them) to exact versions, so CI
# installs the same thing every run instead of whatever is newest that morning —
# and the tool's behaviour is load-bearing here, so a silent upgrade is a silent
# change to what the gate checks. It also satisfies zizmor's adhoc-packages
# audit, which flags unlocked installs in a workflow as supply-chain surface.
#
# Regenerate after changing a version, keeping BOTH platforms — CI runs on
# arm64 macOS and the web sandbox on x86_64 Linux, and Nokogiri ships separate
# native builds, so a single-platform lock fails to install on the other:
#   bundle lock --add-platform arm64-darwin x86_64-linux
source "https://rubygems.org"

gem "html-proofer", "~> 5.2"
