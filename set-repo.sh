#!/usr/bin/env bash
#
# Point every manifest (and platform.env) at the Git repo you pushed this folder to.
#   ./set-repo.sh https://github.com/<you>/k8s-platform-lab.git

set -euo pipefail
cd "$(dirname "$0")"
new=${1:?usage: ./set-repo.sh <git url>}
source ./platform.env
old=$REPO_URL
[[ $old == "$new" ]] && { echo "Already pointing at $new"; exit 0; }
grep -rlF "$old" --include='*.yaml' --include='*.env' . | while read -r f; do
    sed -i "s|$old|$new|g" "$f"
    echo "updated $f"
done
echo "Now commit and push, then run ./up.sh"
