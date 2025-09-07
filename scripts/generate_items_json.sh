#!/usr/bin/env bash
set -euo pipefail

# usage: scripts/generate_items_json.sh <branch_name>
# このスクリプトは特定のブランチのworktreeディレクトリ内で実行される想定

BRANCH="${1:?branch name required (stable|preview)}"
ITEMS_TEXTURE_PATH="resource_pack/textures/items"

echo "=== Generating items JSON for $BRANCH ==="

# 現在のディレクトリが対象のworktreeであることを確認
if [[ ! -d "bedrock_samples" ]]; then
    echo "Error: bedrock_samples directory not found in current directory"
    echo "This script should be run from within the worktree directory"
    exit 1
fi

cd bedrock_samples

# アイテムテクスチャディレクトリが存在するかチェック
if [[ ! -d "$ITEMS_TEXTURE_PATH" ]]; then
    echo "Warning: $ITEMS_TEXTURE_PATH not found in $BRANCH, creating empty JSON"
    cd ..
    printf '{"metadata":{"channel":"%s","samples_tag":"unknown","bds_version":"unknown","generated_at":"%s","total_items":0},"items":[]}\n' \
        "$BRANCH" "$(date -u +%FT%TZ)" > "items_textures.json"
    
    # 空のJSONでもコミット
    git add items_textures.json
    if ! git diff --cached --quiet; then
        git commit -m "[$BRANCH] Add empty items textures JSON (no items directory found)"
        git push origin "$BRANCH" || echo "Warning: Failed to push $BRANCH"
    fi
    exit 0
fi

echo "Scanning items textures in $ITEMS_TEXTURE_PATH for $BRANCH..."

# メタ情報を取得
SAMPLES_TAG="unknown"
BDS_VERSION="unknown"
if [[ -f "../.bds-meta.json" ]]; then
    SAMPLES_TAG="$(jq -r '.samples_tag // "unknown"' "../.bds-meta.json")"
    BDS_VERSION="$(jq -r '.bds_version // "unknown"' "../.bds-meta.json")"
fi

# アイテムテクスチャファイルをスキャン
ITEMS_ARRAY="[]"

# .pngファイルを検索してJSONに変換
while IFS= read -r -d '' file; do
    # フルパスから相対パスを生成
    REL_PATH="${file#./}"
    # ファイル名（拡張子なし）をIDとして使用
    BASENAME="$(basename "$file" .png)"
    # ディレクトリ構造を保持したパス
    DIR_PATH="$(dirname "$REL_PATH")"
    
    # ファイル情報をJSONオブジェクトとして追加
    ITEM_OBJ=$(jq -n \
        --arg id "$BASENAME" \
        --arg path "$REL_PATH" \
        --arg dir "$DIR_PATH" \
        --arg filename "$(basename "$file")" \
        '{
            id: $id,
            texture_path: $path,
            directory: $dir,
            filename: $filename
        }')
    
    ITEMS_ARRAY=$(jq --argjson item "$ITEM_OBJ" '. + [$item]' <<<"$ITEMS_ARRAY")
    
done < <(find "$ITEMS_TEXTURE_PATH" -name "*.png" -type f -print0 | sort -z)

# アイテム数をカウント
ITEM_COUNT=$(jq 'length' <<<"$ITEMS_ARRAY")

echo "Found $ITEM_COUNT item textures in $BRANCH"

# 最終的なJSONを生成
FINAL_JSON=$(jq -n \
    --arg channel "$BRANCH" \
    --arg samples_tag "$SAMPLES_TAG" \
    --arg bds_version "$BDS_VERSION" \
    --arg generated_at "$(date -u +%FT%TZ)" \
    --argjson items "$ITEMS_ARRAY" \
    --argjson count "$ITEM_COUNT" \
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
cd ..
echo "$FINAL_JSON" > "items_textures.json"

echo "Generated items_textures.json for $BRANCH with $ITEM_COUNT items"

# Git に追加してコミット
git add items_textures.json
if ! git diff --cached --quiet; then
    # コミットメッセージを作成
    COMMIT_MSG="[$BRANCH] Add items textures JSON: ${ITEM_COUNT} items"
    [[ "$SAMPLES_TAG" != "unknown" ]] && COMMIT_MSG="$COMMIT_MSG (${SAMPLES_TAG})"
    [[ "$BDS_VERSION" != "unknown" && "$BDS_VERSION" != "$SAMPLES_TAG" ]] && COMMIT_MSG="$COMMIT_MSG / BDS ${BDS_VERSION}"
    
    echo "Committing items JSON to $BRANCH: $COMMIT_MSG"
    git commit -m "$COMMIT_MSG"
    
    # プッシュ
    echo "Pushing $BRANCH to origin..."
    if git push origin "$BRANCH"; then
        echo "Successfully pushed $BRANCH with items JSON"
    else
        echo "Warning: Failed to push $BRANCH (this may be expected in some cases)"
    fi
else
    echo "No changes in items_textures.json for $BRANCH"
fi

# サマリー情報を出力
echo "=== $BRANCH Item Textures Summary ==="
echo "Samples Tag: $SAMPLES_TAG"
echo "BDS Version: $BDS_VERSION"
echo "Total Items: $ITEM_COUNT"

# ディレクトリ別の統計も出力
if [[ $ITEM_COUNT -gt 0 ]]; then
    echo ""
    echo "=== $BRANCH Directory Statistics ==="
    jq -r '.items | group_by(.directory) | .[] | "\(.[0].directory): \(length) items"' "items_textures.json" | sort
    
    echo ""
    echo "=== $BRANCH Sample Items (first 5) ==="
    jq -r '.items[:5] | .[] | "- \(.id) (\(.texture_path))"' "items_textures.json"
fi

echo "=== Items JSON Generation Complete for $BRANCH ==="
