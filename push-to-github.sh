#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL='https://github.com/suckdrygod/tcpping.git'

git init
git add .
git commit -m 'feat: TCP-only safe Komari agent overlay'
git branch -M main
git remote add origin "$REPO_URL" 2>/dev/null || git remote set-url origin "$REPO_URL"
git push -u origin main

echo 'Repository pushed. Create a release build with:'
echo '  git tag v1.2.13-safe.1 && git push origin v1.2.13-safe.1'
