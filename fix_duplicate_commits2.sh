#!/usr/bin/env bash
# dedup-commits.sh — drop duplicate commits (by patch-id) non-interactively
# Works on Ubuntu (20.04/22.04+), macOS too.
set -euo pipefail
export LC_ALL=C

BRANCH="${1:-$(git rev-parse --abbrev-ref HEAD)}"
MODE="${2:-}"           # optional: --dry-run

# ---- helpers ---------------------------------------------------------------
err(){ echo "✗ $*" >&2; exit 1; }
ok(){  echo "✓ $*"; }
info(){ echo "• $*"; }

need(){
  command -v "$1" >/dev/null 2>&1 || err "Required command '$1' not found"
}

git_min_ver(){
  # require >= 2.25 (rebase --root, --rebase-merges stable)
  local need_major=2 need_minor=25
  local ver
  ver="$(git version | awk '{print $3}')"
  local major minor
  major="${ver%%.*}"
  minor="${ver#*.}"; minor="${minor%%.*}"
  if [ "$major" -lt "$need_major" ] || { [ "$major" -eq "$need_major" ] && [ "$minor" -lt "$need_minor" ]; }; then
    err "Git $ver too old. Need >= 2.25"
  fi
}

# ---- checks ---------------------------------------------------------------
need git; need awk
git_min_ver

git rev-parse --git-dir >/dev/null 2>&1 || err "Not a git repository"
git rev-parse --verify "$BRANCH" >/dev/null 2>&1 || err "Branch '$BRANCH' not found"

# Ensure clean tree
git diff --quiet || err "Working tree has changes. Commit/stash first."
git diff --cached --quiet || err "Index has staged changes. Commit/stash first."

# ---- collect commits & patch-ids ------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

COMMITS="$TMP_DIR/commits.txt"
PATCHES="$TMP_DIR/patches.txt"
DUPS="$TMP_DIR/dups.txt"
TODO_MOD="$TMP_DIR/todo-mod.sh"

# linear list oldest..newest, skip merges (patch-id на merge в будь-якому разі беззмістовний)
git rev-list --no-merges --reverse "$BRANCH" > "$COMMITS"

: > "$PATCHES"
while IFS= read -r SHA; do
  # get raw diff; empty if commit has no patch (e.g., revert to same content)
  DIFF="$(git show -p --pretty=format: "$SHA" || true)"
  [ -z "$DIFF" ] && continue
  # stable patch-id: "<pid> <sha>"
  PID="$(printf "%s" "$DIFF" | git patch-id --stable | awk '{print $1}')"
  [ -n "$PID" ] && printf "%s %s\n" "$PID" "$SHA" >> "$PATCHES"
done < "$COMMITS"

# find duplicates: keep first SHA per patch-id, drop subsequent
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
  echo "Would drop these commits:"
  cat "$DUPS"
  exit 0
fi

# ---- backup & checkout -----------------------------------------------------
git fetch origin "$BRANCH":"$BRANCH" || true
git checkout "$BRANCH" >/dev/null 2>&1 || err "Cannot checkout '$BRANCH'"

BACKUP="backup/${BRANCH}-dedup-$(date +%Y%m%d-%H%M%S)"
git branch "$BACKUP"
info "Backup branch created: $BACKUP"

# ---- prepare non-interactive sequence editor ------------------------------
# Store list of SHAs to drop in .git/info/dups-to-drop
DUPS_INFO="$(git rev-parse --git-path info/dups-to-drop)"
cat "$DUPS" > "$DUPS_INFO"

cat > "$TODO_MOD" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TODO_FILE="$1"
DUPS_FILE="$(git rev-parse --git-path info/dups-to-drop)"

# Build a set of SHAs to drop
awk 'NR==FNR{drop[$1]=1; next} {
  # Rebase todo format lines like: "pick <sha> <msg...>"
  # If SHA is in drop-set, change 'pick' to 'drop'
  if ($1=="pick" && ($2 in drop)) {$1="drop"}
  print $0
}' "$DUPS_FILE" "$TODO_FILE" > "${TODO_FILE}.new"

mv "${TODO_FILE}.new" "$TODO_FILE"
EOF
chmod +x "$TODO_MOD"

# ---- rewrite history from root --------------------------------------------
info "Rewriting history from --root to drop duplicates…"
GIT_SEQUENCE_EDITOR="$TODO_MOD" git rebase -i --rebase-merges --root

# ---- push ------------------------------------------------------------------
info "Pushing with --force-with-lease…"
git push --force-with-lease

ok "Done. Dropped $DUPS_COUNT duplicate commit(s)."
echo "Backup branch: $BACKUP"