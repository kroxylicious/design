#!/bin/bash
#
# Copyright Kroxylicious Authors.
#
# Licensed under the Apache Software License version 2.0, available at http://www.apache.org/licenses/LICENSE-2.0
#

# Script to notify authors of open proposal PRs to rebase on main
# Once they rebase, the workflow will automatically check their proposal numbering

set -e

OPEN_PRS=(70 82 83 85 88 93 94 96 98 99 100 101 103)

echo "This script will comment on ${#OPEN_PRS[@]} open proposal PRs"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted"
    exit 1
fi

for pr in "${OPEN_PRS[@]}"; do
    echo "Processing PR #$pr..."

    # Get the proposal file(s) from this PR
    PROPOSAL_FILES=$(gh pr view "$pr" --json files --jq '.files[].path' | grep '^proposals/.*\.md$' | grep -v 'proposals/README.md' | grep -v 'proposals/000-template.md' || true)

    if [ -z "$PROPOSAL_FILES" ]; then
        echo "  No proposal files found, skipping"
        continue
    fi

    # Get the first proposal file (should only be one)
    PROPOSAL_FILE=$(echo "$PROPOSAL_FILES" | head -1)
    CURRENT_FILENAME=$(basename "$PROPOSAL_FILE")
    EXPECTED_FILENAME=$(printf "%03d-" "$pr")$(echo "$CURRENT_FILENAME" | sed 's/^[0-9]*-//' | sed 's/^[a-z]*-//')

    # Build PR-specific comment
    COMMENT_BODY="Hi! We've updated the proposal numbering system to use PR numbers as proposal identifiers.

**Action required:** Please rebase your PR on \`main\`.

Once you rebase, you'll need to rename your proposal file and update the title:

\`\`\`bash
git mv $PROPOSAL_FILE proposals/$EXPECTED_FILENAME
# Update title: remove any old number prefix and add PR number
sed -i.bak '0,/^# /{s/^# \\([0-9]\\{3\\}\\|xxx\\|nnn\\|000\\) - /# $pr - /; t; s/^# /# $pr - /}' proposals/$EXPECTED_FILENAME && rm proposals/$EXPECTED_FILENAME.bak
git add proposals/$EXPECTED_FILENAME
git commit -m \"Rename proposal to use PR number\"
git push
\`\`\`

The GitHub workflow will automatically check your proposal file naming after you push and update this PR description if any corrections are still needed.

See [proposals/README.md](https://github.com/kroxylicious/design/blob/main/proposals/README.md) for the updated workflow."

    echo "  Commenting on PR #$pr (file: $CURRENT_FILENAME → $EXPECTED_FILENAME)..."
    gh pr comment "$pr" --body "$COMMENT_BODY"
    echo "  ✓ PR #$pr notified"
    sleep 2  # Be nice to the API
done

echo ""
echo "✓ All open proposal PRs have been notified"
echo ""
echo "Once authors rebase, the workflow will automatically:"
echo "  1. Detect if their proposal file naming is incorrect"
echo "  2. Update their PR description with the exact command to fix it"
echo "  3. Remove the warning once they fix the naming"
