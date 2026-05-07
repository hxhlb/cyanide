#!/usr/bin/env bash
# Build, optionally commit + push, and publish the resulting IPA as a
# GitHub Release.
#
# Usage:
#   ./scripts/release.sh                           # use working-tree state, build + push (no commit)
#   ./scripts/release.sh "commit message"          # commit any changes, push, build, release
#   TAG=my-tag ./scripts/release.sh "..."          # override tag (defaults to build-<shorthash>)
#
# Requires: git, gh (authenticated), xcodebuild.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v gh >/dev/null; then
    echo "error: gh CLI not installed (brew install gh)" >&2
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh not authenticated (gh auth login)" >&2
    exit 1
fi

MSG="${1:-}"
BRANCH=$(git rev-parse --abbrev-ref HEAD)

# 1. Commit if there are changes and a message was provided.
DIRTY=0
if ! git diff-index --quiet HEAD -- || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    DIRTY=1
fi
if [ "$DIRTY" = "1" ]; then
    if [ -z "$MSG" ]; then
        echo "error: working tree has changes but no commit message was provided." >&2
        echo "       pass a message as the first arg, or stash changes." >&2
        exit 1
    fi
    echo "==> committing"
    git add -A
    git commit -m "$MSG"
fi

# 2. Push (no-op if already in sync).
echo "==> pushing $BRANCH"
git push origin "$BRANCH"

# 3. Build the IPA.
./scripts/build.sh
IPA="$PWD/build/kfun.ipa"
if [ ! -f "$IPA" ]; then
    echo "error: $IPA not found after build" >&2
    exit 1
fi

# 4. Tag + release.
HASH=$(git rev-parse --short HEAD)
TAG="${TAG:-build-${HASH}}"
SUBJECT=$(git log -1 --pretty=%s)
NOTES=$(git log -1 --pretty="%B")

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "==> release $TAG already exists; replacing IPA asset"
    gh release upload "$TAG" "$IPA" --clobber
else
    echo "==> creating release $TAG"
    gh release create "$TAG" "$IPA" \
        --title "$TAG: $SUBJECT" \
        --notes "$NOTES"
fi

echo "==> done"
gh release view "$TAG" | head -10
