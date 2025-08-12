#!/usr/bin/env bash
set -euo pipefail

# main = stable と preview を合体（ルートに stable/ と preview/ を並べる）

git fetch origin --prune
# main をベースに
if git ls-remote --heads origin main | grep -q main; then
  git checkout main
  git merge --ff-only origin/main || true
else
  git checkout -b main
fi

# worktreeで stable / preview をチェックアウト
rm -rf _wt || true
mkdir -p _wt
git worktree add --force _wt/stable  origin/stable
git worktree add --force _wt/preview origin/preview

# 既存を消して差し替え
rm -rf stable preview
mkdir -p stable preview

# 余計な .git 等は除外してコピー
( shopt -s dotglob; cp -a _wt/stable/*  stable/ || true )
( shopt -s dotglob; cp -a _wt/preview/* preview/ || true )

# 後片付け
git worktree remove --force _wt/stable
git worktree remove --force _wt/preview
rm -rf _wt

# コミット＆push（差分があるときのみ）
git add -A
if git diff --cached --quiet; then
  echo "main: no changes."
else
  # メタがあれば表示用に拾う（なくてもOK）
  S_VER="$(jq -r '.bds_version // empty' stable/.bds-meta.json  2>/dev/null || true)"
  P_VER="$(jq -r '.bds_version // empty' preview/.bds-meta.json 2>/dev/null || true)"
  MSG="[main] merge stable(${S_VER:-?}) + preview(${P_VER:-?})"
  git commit -m "$MSG"
  git push -u origin main || git push origin main || true
fi

echo "Done: main updated."
