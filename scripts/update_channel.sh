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

# --- 変更なければ終了（ただし強制フラグがある場合は継続） ---
if [[ "$BDS_VER" == "$OLD_VER" && "$SAMPLES_TAG" == "$OLD_TAG" && "${FORCE_ITEMS_JSON:-false}" != "true" ]]; then
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

# --- アイテムテクスチャJSON生成（デバッグ強化版） ---
generate_items_json() {
  local items_path="bedrock_samples/resource_pack/textures/items"
  local output_file="items_textures.json"
  
  echo "=== Debugging items texture generation for $CHANNEL ==="
  
  # bedrock_samples ディレクトリの存在確認
  if [[ ! -d "bedrock_samples" ]]; then
    echo "ERROR: bedrock_samples directory not found!"
    echo "Current directory: $(pwd)"
    echo "Contents: $(ls -la)"
    return 1
  fi
  
  echo "✓ bedrock_samples directory found"
  
  # resource_pack の構造を調査
  echo "--- bedrock_samples structure ---"
  find bedrock_samples -maxdepth 3 -type d | sort
  
  # texture関連のディレクトリを探す
  echo "--- Looking for texture directories ---"
  find bedrock_samples -type d -name "*texture*" -o -name "*item*" | sort
  
  # PNG ファイルを全体から探す
  echo "--- Looking for PNG files (first 20) ---"
  find bedrock_samples -name "*.png" -type f | head -20
  
  # 期待されるパスの確認
  if [[ ! -d "$items_path" ]]; then
    echo "WARNING: Expected path $items_path not found"
    
    # 代替パスを探す
    echo "--- Searching for alternative item texture paths ---"
    local alt_paths=(
      "bedrock_samples/resource_pack/textures/item_texture"
      "bedrock_samples/resource_packs/vanilla/textures/items"
      "bedrock_samples/behavior_packs/vanilla_gametest/textures/items"
      "bedrock_samples/resource_pack/textures"
    )
    
    local found_path=""
    for alt_path in "${alt_paths[@]}"; do
      if [[ -d "$alt_path" ]]; then
        echo "✓ Alternative path found: $alt_path"
        if find "$alt_path" -name "*.png" -type f | head -1 >/dev/null; then
          found_path="$alt_path"
          break
        fi
      fi
    done
    
    if [[ -n "$found_path" ]]; then
      items_path="$found_path"
      echo "Using alternative path: $items_path"
    else
      echo "Creating empty JSON - no item textures found"
      printf '{"metadata":{"channel":"%s","samples_tag":"%s","bds_version":"%s","generated_at":"%s","total_items":0,"debug":"no_items_directory"},"items":[]}\n' \
        "$CHANNEL" "$SAMPLES_TAG" "$BDS_VER" "$(date -u +%FT%TZ)" > "$output_file"
      return 0
    fi
  fi
  
  echo "✓ Using items path: $items_path"
  echo "--- Contents of $items_path ---"
  ls -la "$items_path" | head -10
  
  # アイテムテクスチャファイルをスキャン
  local items_array="[]"
  local file_count=0
  
  echo "--- Scanning for PNG files ---"
  # .pngファイルを検索してJSONに変換
  while IFS= read -r -d '' file; do
    ((file_count++))
    [[ $file_count -le 5 ]] && echo "Processing: $file"
    
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
    
  done < <(cd "$items_path" && find . -name "*.png" -type f -print0 2>/dev/null | sort -z)
  
  # アイテム数をカウント
  local item_count=$(jq 'length' <<<"$items_array")
  
  echo "✓ Found $item_count item textures"
  
  # 最終的なJSONを生成
  local final_json=$(jq -n \
    --arg channel "$CHANNEL" \
    --arg samples_tag "$SAMPLES_TAG" \
    --arg bds_version "$BDS_VER" \
    --arg generated_at "$(date -u +%FT%TZ)" \
    --arg items_path "$items_path" \
    --argjson items "$items_array" \
    --argjson count "$item_count" \
    '{
      metadata: {
        channel: $channel,
        samples_tag: $samples_tag,
        bds_version: $bds_version,
        generated_at: $generated_at,
        total_items: $count,
        items_path_used: $items_path
      },
      items: $items
    }')
  
  # JSONファイルを出力
  echo "$final_json" > "$output_file"
  echo "✓ Generated $output_file with $item_count items"
  
  # 最初の数個のアイテムを表示
  if [[ $item_count -gt 0 ]]; then
    echo "--- Sample items (first 3) ---"
    jq '.items[:3]' "$output_file"
  fi
  
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
