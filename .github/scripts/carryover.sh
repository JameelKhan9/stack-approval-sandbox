#!/usr/bin/env bash
# Carry-over approval (like Gerrit's trivial-rebase copy): approve a pull request's head only when
# its net change against its base is byte-identical to a commit a person approved.
# Reads only: GitHub API, git fetch/merge-base/diff/patch-id in a bare repo. Never runs PR code.
# Env: REPO (owner/name), PR (number), GH_TOKEN. DRY=1 compares without approving.
set -euo pipefail
: "${REPO:?}" "${PR:?}" "${GH_TOKEN:?}"
MARK='<!-- carry-over-approval -->'
owner=${REPO%/*} name=${REPO#*/}

q='query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p){
  state baseRefName headRefOid
  reviews(last:100){nodes{state body submittedAt commit{oid}}}
  timelineItems(last:250,itemTypes:[BASE_REF_CHANGED_EVENT,AUTOMATIC_BASE_CHANGE_SUCCEEDED_EVENT,HEAD_REF_FORCE_PUSHED_EVENT]){nodes{__typename
    ... on BaseRefChangedEvent{createdAt previousRefName}
    ... on AutomaticBaseChangeSucceededEvent{createdAt oldBase}
    ... on HeadRefForcePushedEvent{createdAt beforeCommit{oid} afterCommit{oid}}}}}}}'
pr=$(gh api graphql -f query="$q" -f o="$owner" -f n="$name" -F p="$PR" --jq .data.repository.pullRequest)
j() { jq -r "$@" <<<"$pr"; }

[ "$(j .state)" = OPEN ] || { echo "skip: not open"; exit 0; }
head=$(j .headRefOid) base=$(j .baseRefName)

# Source = the latest verdict from a person; carry-over reviews (marker) never count. It must be an approval.
src=$(j --arg m "$MARK" '[.reviews.nodes[]|select(.state=="APPROVED" or .state=="CHANGES_REQUESTED" or .state=="DISMISSED")|select(.body|contains($m)|not)]|last // empty')
[ -n "$src" ] && [ "$(jq -r .state <<<"$src")" = APPROVED ] || { echo "skip: no standing approval from a person"; exit 0; }
at=$(jq -r .submittedAt <<<"$src") old=$(jq -r .commit.oid <<<"$src")

# GitHub moves a review onto the new head when it keeps an approval across a force push (its own
# stack rebase included). Walk back through force pushes after the review to the commit the person saw.
tcur=9999
for _ in $(seq 20); do
  ev=$(j --arg c "$old" --arg t "$at" --arg u "$tcur" '[.timelineItems.nodes[]|select(.__typename=="HeadRefForcePushedEvent" and .afterCommit.oid==$c and .createdAt>$t and .createdAt<$u)]|last // empty')
  [ -n "$ev" ] || break
  old=$(jq -r .beforeCommit.oid <<<"$ev") tcur=$(jq -r .createdAt <<<"$ev")
done

# Base branch at approval time: the first base change after the review says what it changed from.
oldbase=$(j --arg t "$at" '[.timelineItems.nodes[]|select(.createdAt>$t)|(.previousRefName // .oldBase // empty)]|first // empty')
oldbase=${oldbase:-$base}

# That branch's tip at approval time. A stack layer's branch may since be rebased or deleted, so use the
# lower PR: its tip before its first force push after the review, else refs/pull/<n>/head. Later
# appends to it are harmless: merge-base stops at what the approved commit actually contains.
low=$(gh api "repos/$REPO/pulls?head=$owner:$oldbase&state=all&per_page=100" |
  jq -r --arg t "$at" '[.[]|select(.created_at<=$t)]|max_by(.number)|.number // empty')
if [ -n "$low" ]; then
  oldref=$(gh api graphql -f query='query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p){timelineItems(last:250,itemTypes:[HEAD_REF_FORCE_PUSHED_EVENT]){nodes{... on HeadRefForcePushedEvent{createdAt beforeCommit{oid}}}}}}}' \
    -f o="$owner" -f n="$name" -F p="$low" |
    jq -r --arg t "$at" '[.data.repository.pullRequest.timelineItems.nodes[]|select(.createdAt>$t)]|first|.beforeCommit.oid // empty')
  oldref=${oldref:-refs/pull/$low/head}
else
  oldref=refs/heads/$oldbase # not a PR head, e.g. main: protected against force pushes, so append-only
fi

g=$(mktemp -d); git init -q --bare "$g"; cd "$g"
auth="Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
fetch() { git -c http.extraHeader="$auth" fetch -q --no-tags "https://github.com/$REPO" "$@"; }
fetch "+refs/pull/$PR/head:refs/x/head" "+refs/heads/$base:refs/x/newbase" "$old"
case $oldref in refs/*) fetch "+$oldref:refs/x/oldbase"; oldref=refs/x/oldbase ;; *) fetch "$oldref" ;; esac
[ "$(git rev-parse refs/x/head)" = "$head" ] || { echo "skip: head moved during the run"; exit 0; }

pid() { local mb; mb=$(git merge-base "$1" "$2") && git diff --no-ext-diff --no-textconv -U0 "$mb" "$2" | git patch-id --stable | cut -d' ' -f1; }
a=$(pid "$oldref" "$old" || true) b=$(pid refs/x/newbase "$head" || true)
echo "approved ${old:0:7} on $oldbase (at $at): patch-id ${a:-none}"
echo "head     ${head:0:7} on $base: patch-id ${b:-none}"
[ -n "$a" ] && [ "$a" = "$b" ] || { echo "result: NO MATCH, not approving"; exit 0; }
echo "result: MATCH"

already=$(j --arg h "$head" '[.reviews.nodes[]|select(.state=="APPROVED" and .commit.oid==$h)]|length')
[ "$already" = 0 ] || { echo "skip: head already holds an approval"; exit 0; }
[ "${DRY:-}" = 1 ] && { echo "dry run: would approve"; exit 0; }
# commit_id pins the approval to the head we checked, so a push during the run cannot inherit it.
gh api "repos/$REPO/pulls/$PR/reviews" -f event=APPROVE -f commit_id="$head" \
  -f body="$MARK Carry-over: the net change at ${head:0:7} is identical to ${old:0:7}, approved by a person at $at (patch-id ${a:0:12})." \
  --jq '"approved: review \(.id) on \(.commit_id[0:7])"'
