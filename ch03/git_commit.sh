#!/bin/bash
set -euo pipefail

cd "$HOME/terraform-oreilly-practice"

git add -A

if git diff --cached --quiet; then
  echo "コミットする変更はありません。"
  exit 0
fi

git status --short

read -r -p "上記をコミットしてpushしますか？ [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 0

git commit -m "Update $(date +%Y-%m-%d)"
git push origin main
