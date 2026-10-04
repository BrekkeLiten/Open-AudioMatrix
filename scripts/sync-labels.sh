#!/usr/bin/env bash
# Creates or updates the repository's issue labels from .github/labels.tsv.
# Needs the GitHub CLI authenticated with access to the repo (GH_TOKEN in CI).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

while IFS=$'\t' read -r name color description; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  gh label create "$name" --color "$color" --description "$description" --force
done < "$ROOT_DIR/.github/labels.tsv"
