#!/usr/bin/env bash
set -euo pipefail

CHANNEL="${1:?channel required: stable|preview}"
[[ "$CHANNEL" == "stable" || "$CHANNEL" == "preview" ]] || { echo "invalid channel"; exit 2; }

JSON_URL="https://raw.githubusercontent.com/Bedrock-OSS/BDS-Versions/main/versions.json"
SAMPLES_API="https://api.github.com/repos/Mojang/bedrock-samples/tags?per_page=200"
UA="Mozilla/5.0"
STRICT_SERIES="${STRICT_SERIES:-true}"
BRANCH="$CHANNEL"

# Reliable downloader: retries + HTTP/1.1 fallback
dl() {
  local url="$1" out="$2" try
  for try in 1 2 3 4 5; do
    local extra=()
    [[ $try -ge 3 ]] && extra+=(--http1.1)
    echo "GET $url (try=$try${extra:+, http1.1})"
    if curl -fL -A "$UA" \
         --retry 5 --retry-all-errors --retry-delay 2 --retry-connrefused \
         --connect-timeout 20 --max-time 600 \
         "${extra[@]}" "$url" -o "$out"; then
      return 0
    fi
    sleep $((2**try))
  done
  return 1
}

# Git branch setup
git fetch origin --prune
if git ls-remote --heads origin "$BRANCH" | grep -q "$BRANCH"; then
  git checkout "$BRANCH"
  git merge --ff-only "origin/$BRANCH" || true
else
  git checkout -b "$BRANCH"
fi

# Resolve BDS version (stable/preview)
versions_json="$(curl -fsSL -A "$UA" "$JSON_URL")"
if [[ "$CHANNEL" == "preview" ]]; then
  BDS_VER="$(jq -r '.linux.preview' <<<"$versions_json")"
  WANT_PREV=true;  WANT_TAG="v${BDS_VER}-preview"
else
  BDS_VER="$(jq -r '.linux.stable'  <<<"$versions_json")"
  WANT_PREV=false; WANT_TAG="v${BDS_VER}"
fi

# Previous meta for early exit
META_FILE=".bds-meta.json"
OLD_VER=""; OLD_TAG=""
[[ -f "$META_FILE" ]] && { OLD_VER="$(jq -r '.bds_version // empty' "$META_FILE")"; OLD_TAG="$(jq -r '.samples_tag // empty' "$META_FILE")"; }

# Fetch tags (use token if available to avoid rate limit)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  HDR=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
else
  HDR=()
fi
tags_json="$(curl -fsSL -A "$UA" "${HDR[@]}" "$SAMPLES_API")"

# Exact match -> use; else nearest (strict series first)
if [[ "$(jq -r --arg T "$WANT_TAG" '[.[]|select(.name==$T)]|length' <<<"$tags_json")" -gt 0 ]]; then
  SAMPLES_TAG="$WANT_TAG"; FALLBACK=false
else
  choose_nearest_strict() { jq -r -f scripts/jq_filter.jq --arg ver "$BDS_VER" --argjson want_prev "$WANT_PREV" --argjson strict true  <<<"$tags_json"; }
  choose_nearest_any()    { jq -r -f scripts/jq_filter.jq --arg ver "$BDS_VER" --argjson want_prev "$WANT_PREV" --argjson strict false <<<"$tags_json"; }

  SAMPLES_TAG=""
  if [[ "${STRICT_SERIES,,}" == "true" ]]; then SAMPLES_TAG="$(choose_nearest_strict || true)"; fi
  [[ -n "$SAMPLES_TAG" ]] || SAMPLES_TAG="$(choose_nearest_any || true)"
  [[ -n "$SAMPLES_TAG" ]] || { echo "::error::No nearest tag found for $CHANNEL"; exit 1; }
  FALLBACK=true
fi

# Skip if nothing changed (saves bandwidth)
if [[ "$BDS_VER" == "$OLD_VER" && "$SAMPLES_TAG" == "$OLD_TAG" ]]; then
  echo "No changes for $CHANNEL. Skip downloads/commit."
  if ! git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    git push -u origin "$BRANCH" || true
  fi
  exit 0
fi

# Download BDS
BDS_URL="https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-${BDS_VER}.zip"
echo "Downloading BDS: $BDS_URL"
rm -rf bedrock_server
mkdir -p bedrock_server
dl "$BDS_URL" bds.zip
unzip -q bds.zip -d bedrock_server || { echo "unzip failed for BDS"; rm -f bds.zip; exit 1; }
rm -f bds.zip

# Ignore huge binary in commits
touch .gitignore
grep -qxF 'bedrock_server/bedrock_server' .gitignore || echo 'bedrock_server/bedrock_server' >> .gitignore

# Download bedrock-samples
SAMPLES_URL="https://github.com/Mojang/bedrock-samples/archive/refs/tags/${SAMPLES_TAG}.zip"
echo "Downloading samples: $SAMPLES_URL"
rm -rf bedrock_samples
dl "$SAMPLES_URL" samples.zip
unzip -q samples.zip
SRC_DIR="$(ls -d bedrock-samples-* | head -n1)"
mkdir -p bedrock_samples
shopt -s dotglob
mv "$SRC_DIR"/* bedrock_samples/
rmdir "$SRC_DIR"
rm -f samples.zip

# Write meta
printf '{"channel":"%s","bds_version":"%s","samples_tag":"%s","fallback_used":%s,"updated_at":"%s"}\n' \
  "$CHANNEL" "$BDS_VER" "$SAMPLES_TAG" "$FALLBACK" "$(date -u +%FT%TZ)" > "$META_FILE"

# Commit & push
git add -A
if git diff --cached --quiet; then
  echo "No staged changes."
else
  MSG="[${CHANNEL}] BDS ${BDS_VER} / samples ${SAMPLES_TAG}"
  [[ "$FALLBACK" == true ]] && MSG="$MSG [fallback]"
  git commit -m "$MSG"
fi

if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
  git push origin "$BRANCH" || true
else
  git push -u origin "$BRANCH" || true
fi

# Tag (mirror bedrock-samples tag). Skip if exists
if git ls-remote --tags origin | grep -q "refs/tags/$SAMPLES_TAG$"; then
  echo "Tag $SAMPLES_TAG already exists on remote."
else
  git tag "$SAMPLES_TAG" || true
  git push origin "refs/tags/$SAMPLES_TAG" || true
fi

echo "Done: $CHANNEL => BDS $BDS_VER, samples $SAMPLES_TAG (fallback=$FALLBACK)"
