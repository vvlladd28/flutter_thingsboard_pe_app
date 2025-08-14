#!/usr/bin/env bash
# dedup-commits.sh — Drop duplicate commits (by patch-id) non-interactively
# Linux/Ubuntu friendly
set -euo pipefail
export LC_ALL=C

BRANCH="${1:-$(git rev-parse --abbrev-ref HEAD)}"
MODE="${2:-}"                    # optional: --dry-run
REMOTE="${REMOTE:-origin}"       # override via env: REMOTE=fork ./dedup-commits.sh <branch>

err(){ echo "✗ $*" >&2; exit 1; }
ok(){  echo "✓ $*"; }
info(){ echo "• $*"; }

need(){ command -v "$1" >/dev/null 2>&1 || err "Required command '$1' not found"; }

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

cleanup(){ [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR" || true; }
trap cleanup EXIT

# --- checks
need git; need awk
git_min_ver
git rev-parse --git-dir >/dev/null 2>&1 || err "Not a git repository"
git rev-parse --verify "$BRANCH" >/dev/null 2>&1 || err "Branch '$BRANCH' not found"
git remote get-url "$REMOTE" >/dev/null 2>&1 || err "Remote '$REMOTE' not found"

git diff --quiet || err "Working tree has changes. Commit/stash first."
git diff --cached --quiet || err "Index has staged changes. Commit/stash first."

# --- optional sync with remote (no fetch-into-checked-out)
if git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
  info "Syncing '$BRANCH' with '$REMOTE/$BRANCH' (ff-only)…"
  if ! git pull --ff-only "$REMOTE" "$BRANCH"; then
    info "FF-only pull not possible (diverged); continuing with local history."
  fi
  UPSTREAM_EXISTS=1
else
  info "Remote branch '$REMOTE/$BRANCH' does not exist; will create it on push."
  UPSTREAM_EXISTS=0
fi

# --- collect commits & patch-ids
TMP_DIR="$(mktemp -d)"
COMMITS="$TMP_DIR/commits.txt"
PATCHES="$TMP_DIR/patches.txt"
DUPS="$TMP_DIR/dups.txt"
TODO_MOD="$TMP_DIR/todo-mod.sh"

# linear list oldest..newest, skip merges
git rev-list --no-merges --reverse "$BRANCH" -- > "$COMMITS"

: > "$PATCHES"
while IFS= read -r SHA; do
  DIFF="$(git show -p --pretty=format: "$SHA" || true)"
  [ -z "$DIFF" ] && continue
  PID="$(printf "%s" "$DIFF" | git patch-id --stable | awk '{print $1}')"
  [ -n "$PID" ] && printf "%s %s\n" "$PID" "$SHA" >> "$PATCHES"
done < "$COMMITS"

awk ' {pid=$1; sha=$2; if(!(pid in seen)){seen[pid]=sha}else{print sha}} ' "$PATCHES" > "$DUPS"

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

# --- ensure on target branch
git checkout "$BRANCH" >/dev/null 2>&1 || err "Cannot checkout '$BRANCH'"

# --- backup
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="backup/${BRANCH}-dedup-${STAMP}"
git branch "$BACKUP"
info "Backup branch created: $BACKUP"

# --- non-interactive sequence editor
DUPS_INFO="$(git rev-parse --git-path info/dups-to-drop)"
cat "$DUPS" > "$DUPS_INFO"

cat > "$TODO_MOD" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TODO_FILE="$1"
DUPS_FILE="$(git rev-parse --git-path info/dups-to-drop)"

# Зчитаємо SHA дублікатів у масив (повні SHA)
# Потім для кожного рядка todo беремо sha2 (може бути скорочений) і перевіряємо:
#  - чи якийсь дубль починається з sha2
#  - або сам sha2 (якщо повний) починається з дубля (рідко, але надійніше)
awk '
  NR==FNR {
    dupc[$1]=1; dups[dc++]=$1; next
  }
  {
    # Рядки todo можуть виглядати як:
    #   pick <sha> <msg...>
    #   reword <sha> <msg...>
    #   edit <sha> <msg...>
    #   squash <sha> <msg...>
    #   fixup <sha> <msg...>
    #   exec <cmd...>     # пропускаємо
    #   label/reset/merge  # з --rebase-merges; пропускаємо
    action=$1
    if (action=="pick" || action=="reword" || action=="edit" || action=="squash" || action=="fixup") {
      sha=$2
      drop_it=0
      # Перевірка за префіксом у два боки
      for (i=0;i<dc;i++){
        d=dups[i]
        # if todo-sha є префіксом повного dup SHA
        if (index(d, sha)==1) { drop_it=1; break }
        # або (на випадок якщо в todo повний sha, а в списку теоретично короткий)
        if (index(sha, d)==1) { drop_it=1; break }
      }
      if (drop_it==1) { action="drop" }
      printf "%s %s", action, sha
      for (i=3;i<=NF;i++){ printf " %s", $i }
      printf "\n"
    } else {
      print $0
    }
  }
' "$DUPS_FILE" "$TODO_FILE" > "${TODO_FILE}.new"

mv "${TODO_FILE}.new" "$TODO_FILE"
EOF
chmod +x "$TODO_MOD"

# --- diagnostics before
LOCAL_BEFORE="$(git rev-parse HEAD)"
REMOTE_BEFORE="$(git ls-remote -q "$REMOTE" "refs/heads/$BRANCH" | awk '{print $1}' || true)"
info "HEAD before:   $LOCAL_BEFORE"
info "Remote before: ${REMOTE_BEFORE:-<none>}"

# --- rewrite history
info "Rewriting history from --root to drop duplicates…"
GIT_SEQUENCE_EDITOR="$TODO_MOD" git rebase -i --rebase-merges --root

# --- diagnostics after
LOCAL_AFTER="$(git rev-parse HEAD)"
REMOTE_AFTER="$(git ls-remote -q "$REMOTE" "refs/heads/$BRANCH" | awk '{print $1}' || true)"
info "HEAD after:    $LOCAL_AFTER"
info "Remote after:  ${REMOTE_AFTER:-<none>}"

# --- push (always explicit refspec to chosen remote)
info "Pushing to '$REMOTE' as '$BRANCH'…"
if [ "$UPSTREAM_EXISTS" -eq 1 ]; then
  # force-with-lease against remote tracking ref if present
  git push --force-with-lease "$REMOTE" "HEAD:$BRANCH"
else
  # create remote branch and set upstream
  git push --set-upstream "$REMOTE" "HEAD:$BRANCH"
fi

ok "Done. Dropped $DUPS_COUNT duplicate commit(s)."
echo "Backup branch: $BACKUP"