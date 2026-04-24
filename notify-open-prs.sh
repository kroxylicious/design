#!/bin/bash
#
# Copyright Kroxylicious Authors.
#
# Licensed under the Apache Software License version 2.0, available at http://www.apache.org/licenses/LICENSE-2.0
#

# Script to notify authors of open proposal PRs to rebase on main
# Once they rebase, the workflow will automatically check their proposal numbering

set -e

OPEN_PRS=(70 82 83 85 88 93 94)

COMMENT_BODY="Hi! We've updated the proposal numbering system to use PR numbers as proposal identifiers.

**Action required:** Please rebase your PR on \`main\`.

Once you push, the GitHub workflow will automatically check your proposal file naming and update this PR description with specific instructions if your file needs to be renamed.

See [proposals/README.md](https://github.com/kroxylicious/design/blob/main/proposals/README.md) for the updated workflow."

echo "This script will comment on ${#OPEN_PRS[@]} open proposal PRs"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted"
    exit 1
fi

for pr in "${OPEN_PRS[@]}"; do
    echo "Commenting on PR #$pr..."
    gh pr comment "$pr" --body "$COMMENT_BODY"
    echo "✓ PR #$pr notified"
    sleep 2  # Be nice to the API
done

echo ""
echo "✓ All open proposal PRs have been notified"
echo ""
echo "Once authors rebase, the workflow will automatically:"
echo "  1. Detect if their proposal file naming is incorrect"
echo "  2. Update their PR description with the exact command to fix it"
echo "  3. Remove the warning once they fix the naming"
