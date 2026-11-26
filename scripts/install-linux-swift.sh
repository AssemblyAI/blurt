#!/usr/bin/env bash
# Installs the Swift 6.2 Linux toolchain in a web/Linux sandbox, so the parts of
# it that need no Apple SDK run there: `swift-format` (the formatting authority
# check.sh lints with) and SourceKit (which SwiftLint's Linux build loads for its
# SourceKit-backed rules). The engine itself still can't build on Linux — it
# imports AVFoundation, CoreMedia, `os` and CryptoKit — so the build and the
# tests stay on CI's macos-26.
#
# Where it comes from: download.swift.org is not reachable under the default
# web network policy, and Docker Hub's anonymous pull limit is shared by every
# sandbox behind the proxy, but mirror.gcr.io (Google's Docker Hub mirror)
# serves the official `swift` image without either. The image's toolchain is
# one layer — the swift.org tarball, signature-checked when the image was
# built, unpacked into `/usr` — so this fetches that one layer by digest,
# verifies the digest, and unpacks its `usr/` tree under $PREFIX. The image's
# other layers are Ubuntu 24.04 and the apt packages the toolchain links
# against; this sandbox is the same Ubuntu, so only the missing packages are
# installed.
#
# Pinned: Swift 6.2.4, the 6.2 line CI's Xcode 26 ships (Package.swift is
# swift-tools 6.2). To move, read the new layer's digest from the image's
# manifest (the third, ~1 GB layer) and change SWIFT_VERSION and LAYER_DIGEST
# together.
#
# Idempotent: an existing install only has its links refreshed. Linux only.
set -euo pipefail

SWIFT_VERSION="6.2.4"
IMAGE_DIGEST="sha256:5e2497a9505e5136e2f5bd49d2509ac833a7e6c2c345b2893c61602def9e20f6" # swift:6.2-noble, linux/amd64
LAYER_DIGEST="sha256:09967bfdcef146b02c69b291ba9557fdfea429b80d4dfc511061bd08016058d4"
REGISTRY="https://mirror.gcr.io/v2/library/swift"
PREFIX="/opt/swift-${SWIFT_VERSION}"
BIN_DIR="/usr/local/bin"
# The apt packages the image installs that a stock Ubuntu 24.04 sandbox lacks.
APT_PACKAGES=(libcurl4-openssl-dev libxml2-dev libz3-dev)

if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
  echo "install-linux-swift: Linux x86_64 only; nothing to do" >&2
  exit 0
fi

link_tools() {
  local tool
  for tool in swift swiftc swift-format sourcekit-lsp; do
    if [ -x "$PREFIX/usr/bin/$tool" ]; then
      ln -sf "$PREFIX/usr/bin/$tool" "$BIN_DIR/$tool"
    fi
  done
}

if [ -x "$PREFIX/usr/bin/swift" ]; then
  link_tools
  exit 0
fi

missing=()
for package in "${APT_PACKAGES[@]}"; do
  dpkg -s "$package" >/dev/null 2>&1 || missing+=("$package")
done
if [ "${#missing[@]}" -gt 0 ]; then
  apt-get -qq update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "${missing[@]}" >/dev/null
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/swift-toolchain.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The manifest names the layer; checking it is still there catches a mirror that
# has moved on, with a clearer message than a 404 on the blob.
manifest_accept="application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
curl -fsSL -m 60 -H "Accept: $manifest_accept" "$REGISTRY/manifests/$IMAGE_DIGEST" -o "$work/manifest.json"
if ! grep -q "$LAYER_DIGEST" "$work/manifest.json"; then
  echo "install-linux-swift: image $IMAGE_DIGEST no longer lists layer $LAYER_DIGEST" >&2
  exit 1
fi

curl -fsSL -m 900 "$REGISTRY/blobs/$LAYER_DIGEST" -o "$work/layer.tar.gz"
actual="sha256:$(shasum -a 256 "$work/layer.tar.gz" | cut -d' ' -f1)"
if [ "$actual" != "$LAYER_DIGEST" ]; then
  echo "install-linux-swift: layer digest mismatch ($actual)" >&2
  exit 1
fi

# Only usr/ — the layer also carries the image's apt bookkeeping — and no
# whiteout markers, which mean something only to an image's overlay filesystem.
mkdir -p "$work/root"
tar -xzf "$work/layer.tar.gz" -C "$work/root" --wildcards --exclude='*/.wh.*' 'usr/*'
rm -rf "$PREFIX"
mkdir -p "$(dirname "$PREFIX")"
mv "$work/root" "$PREFIX"
link_tools
echo "install-linux-swift: Swift ${SWIFT_VERSION} in $PREFIX"
