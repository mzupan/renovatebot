#!/bin/bash
# Mirror PR for testing
# Usage: ./mirror-pr.sh <pr_number> [test_branch_prefix]

set -e

PR_NUM=${1:?"PR number required"}
BRANCH_PREFIX=${2:-"test"}

echo "🔍 Fetching PR #$PR_NUM details..."

# Get PR metadata
PR_DATA=$(gh pr view $PR_NUM --json title,body,headRefName,baseRefName,number)
TITLE=$(echo "$PR_DATA" | jq -r '.title')
BODY=$(echo "$PR_DATA" | jq -r '.body')
HEAD_BRANCH=$(echo "$PR_DATA" | jq -r '.headRefName')
BASE_BRANCH=$(echo "$PR_DATA" | jq -r '.baseRefName')

echo "📋 PR Details:"
echo "  Title: $TITLE"
echo "  From: $HEAD_BRANCH → $BASE_BRANCH"

# Create test branch name
TEST_BRANCH="${BRANCH_PREFIX}/${HEAD_BRANCH}-$(date +%s)"
echo "🌿 Creating test branch: $TEST_BRANCH"

# Ensure we're on base branch and it's up to date
git fetch origin
git checkout $BASE_BRANCH
git pull origin $BASE_BRANCH

# Create and checkout new test branch
git checkout -b $TEST_BRANCH

# Get and apply the diff
echo "📝 Applying PR diff..."
gh pr diff $PR_NUM | git apply

# Check if there are changes
if [[ -z $(git status -s) ]]; then
    echo "⚠️  No changes to commit"
    exit 0
fi

# Commit changes
echo "💾 Committing changes..."
git add -A
git commit -m "Test: $TITLE

Original PR: #$PR_NUM
$BODY

🤖 Generated with mirror-pr script"

# Push to remote
echo "⬆️  Pushing to remote..."
git push -u origin $TEST_BRANCH

# Create test PR
echo "🎯 Creating test PR..."
TEST_PR_BODY="$(cat <<EOF
🧪 **Test PR for #$PR_NUM**

## Original PR Details
$BODY

---
**Original PR**: #$PR_NUM
**Test Branch**: \`$TEST_BRANCH\`
**Created**: $(date)

🤖 This is an automated test PR created from the original PR for testing purposes.
EOF
)"

NEW_PR_URL=$(gh pr create \
    --title "TEST: $TITLE" \
    --body "$TEST_PR_BODY" \
    --base $BASE_BRANCH)

echo "✅ Test PR created: $NEW_PR_URL"
echo ""
echo "🎯 Next steps:"
echo "  1. Run your tests against this PR"
echo "  2. Close the test PR when done: gh pr close <pr_number>"
echo "  3. Delete the test branch: git branch -D $TEST_BRANCH && git push origin --delete $TEST_BRANCH"
