#!/usr/bin/env bash
set -euo pipefail

# main = stable と preview を並置（各ブランチ内容を main の stable/ と preview/ に集約）

git fetch origin --prune
if git ls-remote --heads origin main | grep -q main; then
  git checkout main
  git merge --ff-only origin/main || true
else
  git checkout -b main
fi

rm -rf _wt || true
mkdir -p _wt

if git ls-remote --heads origin stable | grep -q stable; then
  git worktree add --force _wt/stable  origin/stable
fi
if git ls-remote --heads origin preview | grep -q preview; then
  git worktree add --force _wt/preview origin/preview
fi

# 以前の統合結果をクリアして再構築
rm -rf stable preview
mkdir -p stable preview

# 中身だけコピー（.git等は除外）
if [[ -d _wt/stable  ]]; then ( shopt -s dotglob; cp -a _wt/stable/*  stable/  || true ); fi
if [[ -d _wt/preview ]]; then ( shopt -s dotglob; cp -a _wt/preview/* preview/ || true ); fi

# worktreeを片付け
[[ -d _wt/stable  ]] && git worktree remove --force _wt/stable
[[ -d _wt/preview ]] && git worktree remove --force _wt/preview
rm -rf _wt

# mainでは stable/ と preview/ をコミット対象にする（.gitignoreは触らない）
git add -A
if git diff --cached --quiet; then
  echo "main: no changes."
else
  S_VER="$(jq -r '.bds_version // empty' stable/.bds-meta.json  2>/dev/null || true)"
  P_VER="$(jq -r '.bds_version // empty' preview/.bds-meta.json 2>/dev/null || true)"
  MSG="[main] merge stable(${S_VER:-?}) + preview(${P_VER:-?})"
  git commit -m "$MSG"
  if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    git push || true
  else
    git push -u origin main || true
  fi
fi

echo "Done: main updated."
