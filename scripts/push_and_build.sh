#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== 1. Checking GitHub CLI login ==="
if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub 로그인이 필요합니다. 브라우저 로그인을 시작합니다..."
  gh auth login -p https -w
fi
gh auth setup-git

echo "=== 2. Pushing main to origin ==="
git push origin main

echo "=== 3. Waiting for GitHub Actions macOS build ==="
sleep 4
RUN_ID=$(gh run list --workflow "build-ios.yml" --limit 1 --json databaseId --jq '.[0].databaseId')
echo "Watching run #${RUN_ID}..."
gh run watch "$RUN_ID" --exit-status

echo "=== 4. Downloading G2RemoteOS.ipa ==="
rm -rf build/G2RemoteOS.ipa
mkdir -p build
gh run download "$RUN_ID" -n G2RemoteOS-ipa -D build
ls -lh build/G2RemoteOS.ipa
echo "완료! build/G2RemoteOS.ipa 를 아이폰 SideStore로 설치하세요."
