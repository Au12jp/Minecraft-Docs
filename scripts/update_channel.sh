#!/usr/bin/env bash
set -euo pipefail

# usage: scripts/update_channel.sh stable|preview
CHANNEL="${1:?channel required: stable|preview}"
[[ "$CHANNEL" == "stable" || "$CHANNEL" == "preview" ]] || { echo "invalid channel"; exit 2; }

ROOT_DIR="$(pwd)"
JQ_FILTER="$ROOT_DIR/scripts/jq_filter.jq"

BDS_BASE="https://www.minecraft.net/bedrockdedicatedserver"
JSON_URL="https://raw.githubusercontent.com/Bedrock-OSS/BDS-Versions/main/versions.json"
SAMPLES_API="https://api.github.com/repos/Mojang/bedrock-samples/tags?per_page=200"
UA="Mozilla/5.0"
STRICT_SERIES="${STRICT_SERIES:-true}"
BRANCH="$CHANNEL"

# --- リトライ付きダウンロード関数 ---
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

# --- 作業用 worktree ---
git fetch origin --prune
WT_DIR="$ROOT_DIR/_wt/$BRANCH"
mkdir -p "$ROOT_DIR/_wt"

if git ls-remote --heads origin "$BRANCH" | grep -q "$BRANCH"; then
  git worktree add --force -B "$BRANCH" "$WT_DIR" "origin/$BRANCH"
else
  git worktree add --force --detach "$WT_DIR" HEAD
  cd "$WT_DIR"
  git checkout --orphan "$BRANCH"
  find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  cd "$ROOT_DIR"
fi

cd "$WT_DIR"

# --- BDS バージョン解決 ---
versions_json="$(curl -fsSL -A "$UA" "$JSON_URL")"
if [[ "$CHANNEL" == "preview" ]]; then
  BDS_VER="$(jq -r '.linux.preview' <<<"$versions_json")"
  BDS_DIR="bin-linux-preview"
  WANT_PREV=true
  WANT_TAG="v${BDS_VER}-preview"
else
  BDS_VER="$(jq -r '.linux.stable' <<<"$versions_json")"
  BDS_DIR="bin-linux"
  WANT_PREV=false
  WANT_TAG="v${BDS_VER}"
fi

META_FILE=".bds-meta.json"
OLD_VER=""; OLD_TAG=""
[[ -f "$META_FILE" ]] && { OLD_VER="$(jq -r '.bds_version // empty' "$META_FILE")"; OLD_TAG="$(jq -r '.samples_tag // empty' "$META_FILE")"; }

# --- bedrock-samples タグ取得 ---
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  HDR=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
else
  HDR=()
fi
tags_json="$(curl -fsSL -A "$UA" "${HDR[@]}" "$SAMPLES_API")"

# 完全一致を優先、無ければ jq_filter で選択、空なら最新を使う
if [[ "$(jq -r --arg T "$WANT_TAG" '[.[]|select(.name==$T)]|length' <<<"$tags_json")" -gt 0 ]]; then
  SAMPLES_TAG="$WANT_TAG"
  FALLBACK=false
else
  choose_strict() { jq -r -f "$JQ_FILTER" --arg ver "$BDS_VER" --argjson want_prev "$WANT_PREV" --argjson strict true <<<"$tags_json"; }
  choose_any()    { jq -r -f "$JQ_FILTER" --arg ver "$BDS_VER" --argjson want_prev "$WANT_PREV" --argjson strict false <<<"$tags_json"; }

  SAMPLES_TAG=""
  [[ "${STRICT_SERIES,,}" == "true" ]] && SAMPLES_TAG="$(choose_strict || true)"
  [[ -z "$SAMPLES_TAG" ]] && SAMPLES_TAG="$(choose_any || true)"

  # --- 空配列なら最新タグを自動取得 ---
  if [[ -z "$SAMPLES_TAG" || "$SAMPLES_TAG" == "[]" ]]; then
    SAMPLES_TAG=$(jq -r '.[0].name' <<<"$tags_json")
    FALLBACK=true
  else
    FALLBACK=true
  fi
fi

# --- 変更なければ終了 ---
if [[ "$BDS_VER" == "$OLD_VER" && "$SAMPLES_TAG" == "$OLD_TAG" ]]; then
  echo "No changes for $CHANNEL. Skip downloads/commit."
  if ! git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    git push -u origin "$BRANCH" || true
  fi
  cd "$ROOT_DIR"; git worktree remove --force "$WT_DIR" || true
  exit 0
fi

rm -rf stable preview scripts || true

# --- BDS ダウンロード ---
BDS_URL="${BDS_BASE}/${BDS_DIR}/bedrock-server-${BDS_VER}.zip"
echo "Downloading BDS: $BDS_URL"
rm -rf bedrock_server
mkdir -p bedrock_server
dl "$BDS_URL" bds.zip
unzip -q bds.zip -d bedrock_server
rm -f bds.zip
echo "BDS $BDS_VER downloaded successfully."

# --- bedrock-samples ダウンロード ---
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

# --- .gitignore ---
touch .gitignore
grep -qxF 'bedrock_server/bedrock_server' .gitignore || echo 'bedrock_server/bedrock_server' >> .gitignore
for p in stable/ preview/ scripts/ ; do
  grep -qxF "$p" .gitignore || echo "$p" >> .gitignore
done

# --- アイテムテクスチャJSON生成 ---
generate_items_json() {
  local items_path="bedrock_samples/resource_pack/textures/items"
  local output_file="items_textures.json"
  
  echo "Generating items textures JSON for $CHANNEL..."
  
  if [[ ! -d "$items_path" ]]; then
    echo "Warning: $items_path not found, creating empty JSON"
    printf '{"metadata":{"channel":"%s","samples_tag":"%s","bds_version":"%s","generated_at":"%s","total_items":0},"items":[]}\n' \
      "$CHANNEL" "$SAMPLES_TAG" "$BDS_VER" "$(date -u +%FT%TZ)" > "$output_file"
    return 0
  fi
  
  echo "Scanning items textures in $items_path..."
  
  # アイテムテクスチャファイルをスキャン
  local items_array="[]"
  
  # .pngファイルを検索してJSONに変換
  while IFS= read -r -d '' file; do
    # フルパスから相対パスを生成
    local rel_path="${file#./}"
    # ファイル名（拡張子なし）をIDとして使用
    local basename_no_ext="$(basename "$file" .png)"
    # ディレクトリ構造を保持したパス
    local dir_path="$(dirname "$rel_path")"
    
    # ファイル情報をJSONオブジェクトとして追加
    local item_obj=$(jq -n \
      --arg id "$basename_no_ext" \
      --arg path "$rel_path" \
      --arg dir "$dir_path" \
      --arg filename "$(basename "$file")" \
      '{
        id: $id,
        texture_path: $path,
        directory: $dir,
        filename: $filename
      }')
    
    items_array=$(jq --argjson item "$item_obj" '. + [$item]' <<<"$items_array")
    
  done < <(find "$items_path" -name "*.png" -type f -print0 | sort -z)
  
  # アイテム数をカウント
  local item_count=$(jq 'length' <<<"$items_array")
  
  echo "Found $item_count item textures"
  
  # 最終的なJSONを生成
  local final_json=$(jq -n \
    --arg channel "$CHANNEL" \
    --arg samples_tag "$SAMPLES_TAG" \
    --arg bds_version "$BDS_VER" \
    --arg generated_at "$(date -u +%FT%TZ)" \
    --argjson items "$items_array" \
    --argjson count "$item_count" \
    '{
      metadata: {
        channel: $channel,
        samples_tag: $samples_tag,
        bds_version: $bds_version,
        generated_at: $generated_at,
        total_items: $count
      },
      items: $items
    }')
  
  # JSONファイルを出力
  echo "$final_json" > "$output_file"
  echo "Generated $output_file with $item_count items"
  
  # グローバル変数に設定（コミットメッセージで使用）
  ITEM_COUNT="$item_count"
}

# アイテムJSON生成を実行
ITEM_COUNT=0
generate_items_json

# --- メタ書き出し ---
printf '{"channel":"%s","bds_version":"%s","samples_tag":"%s","fallback_used":%s,"updated_at":"%s"}\n' \
  "$CHANNEL" "$BDS_VER" "$SAMPLES_TAG" "$FALLBACK" "$(date -u +%FT%TZ)" > "$META_FILE"

# --- コミット & プッシュ ---
git add -A
if git diff --cached --quiet; then
  echo "No staged changes."
else
  MSG="[${CHANNEL}] BDS ${BDS_VER} / samples ${SAMPLES_TAG}"
  [[ "$FALLBACK" == true ]] && MSG="$MSG [fallback]"
  
  # アイテム数も含める
  if [[ "$ITEM_COUNT" -gt 0 ]]; then
    MSG="$MSG / items ${ITEM_COUNT}"
  fi
  
  git commit -m "$MSG"
fi

if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
  git push origin "$BRANCH" || true
else
  git push -u origin "$BRANCH" || true
fi

# タグ作成（既存ならスキップ）
if git ls-remote --tags origin | grep -q "refs/tags/$SAMPLES_TAG$"; then
  echo "Tag $SAMPLES_TAG already exists on remote."
else
  git tag "$SAMPLES_TAG" || true
  git push origin "refs/tags/$SAMPLES_TAG" || true
fi

cd "$ROOT_DIR"
git worktree remove --force "$WT_DIR" || true

echo "Done: $CHANNEL => BDS $BDS_VER (${BDS_DIR}), samples $SAMPLES_TAG (fallback=$FALLBACK), items $ITEM_COUNT"
