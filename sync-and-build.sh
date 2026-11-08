#!/usr/bin/env bash
# Pull upstream Silo into the personal fork branches and start every build.
#
#   ./sync-and-build.sh              merge upstream, push, build everything
#   ./sync-and-build.sh --check      only report what is new and whether it merges cleanly
#   ./sync-and-build.sh --no-build   merge and push, start no builds
#   ./sync-and-build.sh --build-only start the builds from what is already pushed
#   ./sync-and-build.sh --only server,apple,android   limit to some repos
#
# A repo whose merge conflicts is left untouched (the merge is aborted) and
# reported at the end; resolve it by hand, push, and run with --build-only.
#
# Fork branches:
#   server   Joloxx9/silo-server  main        -> fork-image.yml   -> ghcr.io/joloxx9/silo-server:latest
#   apple    Joloxx9/silo-apple   fork-build  -> silo-mac-build: mac-app.yml + sideload-ipa.yml
#   android  Joloxx9/silo-android fork-build  -> fork-build-apk.yml (runs on push)
set -euo pipefail

OWNER=Joloxx9
GIT_NAME=Joloxx9
GIT_EMAIL=joloxx9@gmail.com
WORK=${WORK:-$HOME/work}
SERVER_DIR=${SERVER_DIR:-$HOME/silo-server}
APPLE_DIR=${APPLE_DIR:-$WORK/silo-apple-mac}
ANDROID_DIR=${ANDROID_DIR:-$WORK/silo-android}

mode=full
only=server,apple,android
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode=check ;;
    --no-build) mode=nobuild ;;
    --build-only) mode=buildonly ;;
    --only) only=$2; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

want() { [[ ",$only," == *",$1,"* ]]; }
g() { git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" "$@"; }

failed=()
summary=()
pushed=()

# sync <key> <dir> <repo> <branch>
sync() {
  local key=$1 dir=$2 repo=$3 branch=$4
  if [ ! -d "$dir/.git" ]; then
    git clone -q "https://github.com/$OWNER/$repo.git" "$dir"
  fi
  cd "$dir"
  git remote get-url upstream >/dev/null 2>&1 \
    || git remote add upstream "https://github.com/Silo-Server/$repo.git"
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    failed+=("$key: $dir has uncommitted changes, skipped")
    return
  fi
  git fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch"
  git fetch -q upstream "+refs/heads/main:refs/remotes/upstream/main"
  local new
  new=$(git rev-list --count "origin/$branch..upstream/main")
  if [ "$new" = 0 ]; then
    summary+=("$key: already has upstream main")
    return
  fi
  if [ "$mode" = check ]; then
    local tmp; tmp=$(mktemp)
    if git merge-tree --write-tree --name-only "origin/$branch" upstream/main >"$tmp" 2>&1; then
      summary+=("$key: $new new upstream commits, merges cleanly")
    else
      summary+=("$key: $new new upstream commits, CONFLICTS in: $(tail -n +2 "$tmp" | sed '/^$/,$d' | tr '\n' ' ')")
    fi
    rm -f "$tmp"
    return
  fi
  if git show-ref -q --verify "refs/heads/$branch"; then
    git checkout -q "$branch"
    git merge -q --ff-only "origin/$branch"
  else
    git checkout -q -b "$branch" "origin/$branch"
  fi
  if ! g merge -q --no-edit upstream/main -m "Merge upstream/main into $branch"; then
    local files
    files=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
    git merge --abort
    failed+=("$key: merge conflicts in: $files")
    return
  fi
  git push -q origin "$branch"
  pushed+=("$key")
  summary+=("$key: merged $new upstream commits and pushed $branch")
}

build_server() {
  gh workflow run fork-image.yml -R "$OWNER/silo-server" --ref main
  summary+=("server: started fork-image.yml")
}
build_apple() {
  gh workflow run mac-app.yml -R "$OWNER/silo-mac-build" \
    -f repository="$OWNER/silo-apple" -f ref=fork-build
  gh workflow run sideload-ipa.yml -R "$OWNER/silo-mac-build" \
    -f repository="$OWNER/silo-apple" -f ref=fork-build -f platform=both
  summary+=("apple: started macOS and iOS/tvOS builds")
}
build_android() {
  # A push to fork-build already started the build.
  if [[ " ${pushed[*]:-} " == *" android "* ]]; then
    summary+=("android: build started by the push")
    return
  fi
  gh workflow run fork-build-apk.yml -R "$OWNER/silo-android" --ref fork-build
  summary+=("android: started fork-build-apk.yml")
}

if [ "$mode" != buildonly ]; then
  want server && sync server "$SERVER_DIR" silo-server main
  want apple && sync apple "$APPLE_DIR" silo-apple fork-build
  want android && sync android "$ANDROID_DIR" silo-android fork-build
fi

if [ "$mode" = full ] || [ "$mode" = buildonly ]; then
  for key in server apple android; do
    want "$key" || continue
    # Do not build a repo whose merge failed; its branch is unchanged.
    if printf '%s\n' "${failed[@]:-}" | grep -q "^$key:"; then continue; fi
    "build_$key"
  done
fi

printf '%s\n' "${summary[@]:-}"
if [ ${#failed[@]} -gt 0 ]; then
  printf 'FAILED %s\n' "${failed[@]}"
  exit 1
fi
