#!/usr/bin/env bash
# dedup-commits.sh — Drop duplicate commits (by patch-id) non-interactively
# Works on Ubuntu (20.04/22.04+), macOS too.
set -euo pipefail
export LC_ALL=C

# --------------------------- CLI --------------------------------------------
BRANCH="${1:-$(git rev-parse --abbrev-ref HEAD)}"
MODE="${2:-}"                 # optional: --dry-run
REMOTE="${REMOTE:-origin}"    # override: REMOTE=upstream ./dedup-commits.sh <branch>

# -------------------------- Utils -------------------------------------------
err(){ echo "✗ $*" >&2; exit 1; }
ok(){  echo "✓ $*"; }
info(){ echo "• $*"; }

need(){
  command -v "$1" >/dev/null 2>&1 || err "Required command '$1' not found"
}

git_min_ver(){
  local need_major=2 need_minor=25
  local ver major minor
  ver="$(git version | awk '{print $3}')" || ver="0.0"
  major="${ver%%.*}"
  minor="${ver#*.}"; minor="${minor%%.*}"
  if [ "${major:-0}" -lt "$need_major" ] || { [ "${major:-0}" -eq "$need_major" ] && [ "${minor:-0}" -lt "$need_minor" ]; }; then
    err "Git $ver too old. Need >= 2.25"
  fi
}

cleanup(){
  [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR" || true
}
trap cleanup EXIT

# -------------------------- Checks ------------------------------------------
need git; need awk
git_min_ver
git rev-parse --git-dir >/dev/null 2>&1 || err "Not a git repository"
git rev-parse --verify "$BRANCH" >/dev/null 2>&1 || err "Branch '$BRANCH' not found"
git remote get-url "$REMOTE" >/dev/null 2>&1 || err "Remote '$REMOTE' not found"

git diff --quiet || err "Working tree has changes. Commit/stash first."
git diff --cached --quiet || err "Index has staged changes. Commit/stash first."

# ---------------------- Collect commits & patch-ids --------------------------
TMP_DIR="$(mktemp -d)"
COMMITS="$TMP_DIR/commits.txt"
PATCHES="$TMP_DIR/patches.txt"
DUPS="$TMP_DIR/dups.txt"
TODO_MOD="$TMP_DIR/todo-mod.sh"

# linear list oldest..newest, skip merges
git rev-list --no-merges --reverse "$BRANCH" -- > "$COMMITS"

: > "$PATCHES"
while IFS= read -r SHA; do
  # raw diff of the commit (empty if no patch)
  DIFF="$(git show -p --pretty=format: "$SHA" || true)"
  [ -z "$DIFF" ] && continue
  PID="$(printf "%s" "$DIFF" | git patch-id --stable | awk '{print $1}')"
  [ -n "$PID" ] && printf "%s %s\n" "$PID" "$SHA" >> "$PATCHES"
done < "$COMMITS"

# keep first SHA per patch-id, mark subsequent as duplicates
awk '
  { pid=$1; sha=$2
    if (!(pid in seen)) { seen[pid]=sha }
    else { print sha }
  }
' "$PATCHES" > "$DUPS"

DUPS_COUNT="$(wc -l < "$DUPS" | tr -d ' ')"
if [ "$DUPS_COUNT" -eq 0 ]; then
  ok "No duplicate commits (by patch-id) on '$BRANCH'."
  exit 0
fi
info "Found $DUPS_COUNT duplicate commit(s) on '$BRANCH'."

if [ "$MODE" = "--dry-run" ]; then
  echo "Would drop these commits (newest duplicates by patch-id):"
  cat "$DUPS"
  exit 0
fi

# -------------------------- Prepare branch -----------------------------------
# Checkout target branch
git checkout "$BRANCH" >/dev/null 2>&1 || err "Cannot checkout '$BRANCH'"

# Make a safety backup branch
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="backup/${BRANCH}-dedup-${STAMP}"
git branch "$BACKUP"
info "Backup branch created: $BACKUP"

# If remote branch exists — prime local with remote state (optional)
if git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
  git fetch "$REMOTE" "$BRANCH:$BRANCH" || true
  UPSTREAM_EXISTS=1
else
  info "Remote '$REMOTE/$BRANCH' does not exist; it will be created on push."
  UPSTREAM_EXISTS=0
fi

# --------------------- Non-interactive rebase editor -------------------------
# Store list of SHAs to drop in .git/info/dups-to-drop
DUPS_INFO="$(git rev-parse --git-path info/dups-to-drop)"
cat "$DUPS" > "$DUPS_INFO"

cat > "$TODO_MOD" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TODO_FILE="$1"
DUPS_FILE="$(git rev-parse --git-path info/dups-to-drop)"

# Build a set of SHAs to drop; modify rebase todo in place
awk 'NR==FNR{drop[$1]=1; next} {
  # Lines look like: "pick <sha> <message…>"
  if ($1=="pick" && ($2 in drop)) {$1="drop"}
  print $0
}' "$DUPS_FILE" "$TODO_FILE" > "${TODO_FILE}.new"

mv "${TODO_FILE}.new" "$TODO_FILE"
EOF
chmod +x "$TODO_MOD"

# -------------------------- Rewrite history ----------------------------------
info "Rewriting history from --root to drop duplicates…"
GIT_SEQUENCE_EDITOR="$TODO_MOD" git rebase -i --rebase-merges --root

# ------------------------------ Push -----------------------------------------
info "Pushing…"
if [ "$UPSTREAM_EXISTS" -eq 1 ]; then
  git push --force-with-lease "$REMOTE" "$BRANCH"
else
  # First push creates the remote & sets upstream
  git push --set-upstream "$REMOTE" "$BRANCH"
fi

ok "Done. Dropped $DUPS_COUNT duplicate commit(s)."
echo "Backup branch: $BACKUP"