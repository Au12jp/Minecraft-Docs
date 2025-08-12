#!/usr/bin/env bash
set -euo pipefail

# Usage: scripts/update_channel.sh stable|preview
CHANNEL="${1:?channel required: stable|preview}"
[[ "$CHANNEL" == "stable" || "$CHANNEL" == "preview" ]] || { echo "invalid channel"; exit 2; }

JSON_URL="https://raw.githubusercontent.com/Bedrock-OSS/BDS-Versions/main/versions.json"
SAMPLES_API="https://api.github.com/repos/Mojang/bedrock-samples/tags?per_page=200"
UA="Mozilla/5.0 (Node scraper)"
GH_HDR=(-H "Authorization: Bearer ${GITHUB_TOKEN:-${GH_TOKEN:-}}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
STRICT_SERIES="${STRICT_SERIES:-true}"   # 同系列(例: 1.21.100.*)優先
BRANCH="$CHANNEL"

# --- Git 初期化 ---
git fetch origin --prune
if git ls-remote --heads origin "$BRANCH" | grep -q "$BRANCH"; then
  git checkout "$BRANCH"
  git merge --ff-only "origin/$BRANCH" || true
else
  git checkout -b "$BRANCH"
fi

# --- 最新BDSバージョン取得（channelに合わせる） ---
versions_json="$(curl -fsSL -A "$UA" "$JSON_URL")"
if [[ "$CHANNEL" == "preview" ]]; then
  BDS_VER="$(jq -r '.linux.preview' <<<"$versions_json")"
  WANT_PREV=true
  WANT_TAG="v${BDS_VER}-preview"
else
  BDS_VER="$(jq -r '.linux.stable' <<<"$versions_json")"
  WANT_PREV=false
  WANT_TAG="v${BDS_VER}"
fi

# 既存メタが同一なら早期終了（ダウンロード回避）
META_FILE=".bds-meta.json"
if [[ -f "$META_FILE" ]]; then
  OLD_VER="$(jq -r '.bds_version // empty' "$META_FILE")"
  OLD_TAG="$(jq -r '.samples_tag // empty' "$META_FILE")"
else
  OLD_VER=""; OLD_TAG=""
fi

# --- bedrock-samples タグ解決（完全一致→近似） ---
tags_json="$(curl -fsSL -A "$UA" "${GH_HDR[@]}" "$SAMPLES_API")"
# 完全一致
if [[ "$(jq -r --arg T "$WANT_TAG" '[.[]|select(.name==$T)]|length' <<<"$tags_json")" -gt 0 ]]; then
  SAMPLES_TAG="$WANT_TAG"; FALLBACK=false
else
  # 近似（同系列優先→全体）
  read -r -d '' JQ_FILTER <<'JQ'
    def parse:
      map(select(.name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+(-preview)?$")))
      | map({
          name: .name,
          is_preview: (.name | contains("-preview")),
          nums: (.name | sub("^v";"") | sub("-preview$";"") | split(".") | map(tonumber))
        });
    def scalar(n): (n[0]*1000000000 + n[1]*1000000 + n[2]*1000 + n[3]);

    parse
    | map(select(.is_preview == $want_prev))
    | ($ver | split(".") | map(tonumber)) as $w
    | if $strict then map(select(.nums[0]==$w[0] and .nums[1]==$w[1] and .nums[2]==$w[2])) else . end
    | if length==0 then [] else
        map(. + {dist: ((scalar(.nums) - scalar($w)) | if . < 0 then -. else . end)})
        | sort_by(.dist, .nums)
        | .[0:1] | .[0].name
      end
JQ
  strict_flag="$STRICT_SERIES"
  SAMPLES_TAG="$(jq -r \
    --arg ver "$BDS_VER" \
    --argjson want_prev "$WANT_PREV" \
    --argjson strict "$strict_flag" \
    "$JQ_FILTER" <<<"$tags_json" || true)"
  if [[ -z "${SAMPLES_TAG:-}" ]]; then
    # 全体から
    SAMPLES_TAG="$(jq -r \
      --arg ver "$BDS_VER" \
      --argjson want_prev "$WANT_PREV" \
      --argjson strict false \
      "$JQ_FILTER" <<<"$tags_json" || true)"
  fi
  [[ -n "${SAMPLES_TAG:-}" ]] || { echo "::error::No nearest tag found for $CHANNEL"; exit 1; }
  FALLBACK=true
fi

# バージョン・タグが以前と同じなら終了（超節約）
if [[ "$BDS_VER" == "$OLD_VER" && "$SAMPLES_TAG" == "$OLD_TAG" ]]; then
  echo "No changes for $CHANNEL. Skip downloads/commit."
  # upstream 未設定ならだけ作っておく
  if ! git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    git push -u origin "$BRANCH" || true
  fi
  exit 0
fi

# --- ダウンロード＆展開 ---
# BDS
BDS_URL="https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-${BDS_VER}.zip"
echo "Downloading BDS: $BDS_URL"
rm -rf bedrock_server
mkdir -p bedrock_server
curl -fL "$BDS_URL" -o bds.zip
unzip -q bds.zip -d bedrock_server
rm -f bds.zip

# 100MB超の実行バイナリは無視（コミットしない）
touch .gitignore
grep -qxF 'bedrock_server/bedrock_server' .gitignore || echo 'bedrock_server/bedrock_server' >> .gitignore

# bedrock-samples
SAMPLES_URL="https://github.com/Mojang/bedrock-samples/archive/refs/tags/${SAMPLES_TAG}.zip"
echo "Downloading samples: $SAMPLES_URL"
rm -rf bedrock_samples
curl -fL "$SAMPLES_URL" -o samples.zip
unzip -q samples.zip
SRC_DIR="$(ls -d bedrock-samples-* | head -n1)"
mkdir -p bedrock_samples
shopt -s dotglob
mv "$SRC_DIR"/* bedrock_samples/
rmdir "$SRC_DIR"
rm -f samples.zip

# メタを書き出し（次回の早期終了に使う）
cat > "$META_FILE" <<EOF
{"channel":"$CHANNEL","bds_version":"$BDS_VER","samples_tag":"$SAMPLES_TAG","fallback_used":$FALLBACK,"updated_at":"$(date -u +%FT%TZ)"}
EOF

# --- コミット＆push（upstream無しも吸収） ---
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

# タグ（自リポに samples と同名を作る。既存はスキップ）
if git ls-remote --tags origin | grep -q "refs/tags/$SAMPLES_TAG$"; then
  echo "Tag $SAMPLES_TAG already exists on remote."
else
  git tag "$SAMPLES_TAG" || true
  git push origin "refs/tags/$SAMPLES_TAG" || true
fi

echo "Done: $CHANNEL => BDS $BDS_VER, samples $SAMPLES_TAG (fallback=$FALLBACK)"
