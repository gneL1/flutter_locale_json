#!/usr/bin/env bash
set -euo pipefail
NEW_VER="$1"                 # 用法：bash scripts/release.sh 0.0.13

git switch main
git pull --rebase origin main

# 在 pubspec.yaml 内就地替换 version 行
sed -i -E "s/^version:.*/version: $NEW_VER/" pubspec.yaml

git add .
git commit -m "chore: bump version to v$NEW_VER"
git tag -a "v$NEW_VER" -m "Release v$NEW_VER"

git push origin main
git push origin "v$NEW_VER"
