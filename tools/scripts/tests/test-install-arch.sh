#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/tools/scripts" "$scratch/arch" "$scratch/bin" "$scratch/local"
# Redirect migration paths and simulate user IDs only in the disposable copy.
sed -e 's|"$HOME/.local/$relative"|"$TEST_LOCAL/$relative"|g' \
    -e 's/if (( EUID == 0 )); then/if (( TEST_EUID == 0 )); then/' \
    "$repo/tools/scripts/install-arch.sh" > "$scratch/tools/scripts/install-arch.sh"
cp "$repo/arch/PKGBUILD" "$scratch/arch/"
export TEST_LOCAL="$scratch/local" TEST_LOG="$scratch/log" TEST_EUID=1000
export TEST_MV="$(command -v mv)"
cat > "$scratch/bin/git" <<'STUB'
#!/usr/bin/env bash
[[ ${TEST_GIT_RC:-0} == 0 ]] || exit "$TEST_GIT_RC"
case "$3" in
    describe) echo v1.5-7-gabcdef-dirty ;;
    submodule)
        [[ $4 == status && $5 == --recursive ]] || exit 99
        echo "${TEST_SUBMODULE_STATUS:-+}abcdef src/backend_scene"
        ;;
    *) exit 99 ;;
esac
STUB
cat > "$scratch/bin/makepkg" <<'STUB'
#!/usr/bin/env bash
[[ $* == '--syncdeps --install --force' && -n $WEK_REPO_ROOT ]] || exit 99
echo makepkg >> "$TEST_LOG"
exit "${TEST_INSTALL_RC:-0}"
STUB
cat > "$scratch/bin/mv" <<'STUB'
#!/usr/bin/env bash
count=0
[[ ! -f $TEST_LOG.moves ]] || read -r count < "$TEST_LOG.moves"
echo "$((count + 1))" > "$TEST_LOG.moves"
if [[ ${TEST_BACKUP_FAIL:-0} == "$((count + 1))" ]] ||
   (( ${TEST_ROLLBACK_FAIL:-0} && count >= 2 )); then
    exit 18
fi
exec "$TEST_MV" "$@"
STUB
cat > "$scratch/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$TEST_LOG"
if [[ $* == '--user restart plasma-plasmashell.service' ]]; then
    exit "${TEST_RESTART_RC:-0}"
fi
exit "${TEST_SYSTEMCTL_RC:-0}"
STUB
# Availability checks must never depend on host pacman/sudo or invoke them.
for command in pacman sudo; do
    printf '#!/usr/bin/env bash\nexit 99\n' > "$scratch/bin/$command"
done
chmod +x "$scratch/bin/"*
# Enough native utilities for a second run with no host directories on PATH.
for command in bash dirname mkdir grep cp sed mktemp flock cat; do
    ln -s "$(command -v "$command")" "$scratch/bin/$command"
done
export PATH="$scratch/bin:$PATH" XDG_RUNTIME_DIR="$scratch/runtime"
run() {
    local rc=0
    rm -f "$TEST_LOG.moves"
    bash "$scratch/tools/scripts/install-arch.sh" > "$scratch/output" 2>&1 || rc=$?
    [[ $rc == "$1" ]] || { cat "$scratch/output"; return 1; }
}
wallpaper=share/plasma/wallpapers/com.github.captsilver.wallpaperEngineKde
module=lib/qt6/qml/com/github/captsilver/wallpaperEngineKde
mkdir -p "$TEST_LOCAL/$wallpaper" "$TEST_LOCAL/$module"
touch "$TEST_LOCAL/$wallpaper/marker" "$TEST_LOCAL/$module/marker"
TEST_EUID=0 run 1
[[ ! -e $TEST_LOG ]]
TEST_SUBMODULE_STATUS=- run 1
[[ ! -e $TEST_LOG ]]
TEST_GIT_RC=19 run 19
[[ ! -e $TEST_LOG ]]
TEST_INSTALL_RC=17 run 17
[[ -e $TEST_LOCAL/$wallpaper/marker && -e $TEST_LOCAL/$module/marker ]]
! compgen -G "$scratch/build/arch-install/user-install-backup-*" >/dev/null
TEST_BACKUP_FAIL=1 run 18
[[ -e $TEST_LOCAL/$wallpaper/marker && -e $TEST_LOCAL/$module/marker ]]
TEST_BACKUP_FAIL=2 run 18
[[ -e $TEST_LOCAL/$wallpaper/marker && -e $TEST_LOCAL/$module/marker ]]
! grep -q restart "$TEST_LOG"
run 0
grep -qx 'pkgver=1.5.r7.gabcdef.dirty' "$scratch/build/arch-install/PKGBUILD"
[[ ! -e $TEST_LOCAL/$wallpaper && ! -e $TEST_LOCAL/$module ]]
saved_wallpaper=("$scratch/build/arch-install/"user-install-backup-*/"$wallpaper/marker")
saved_module=("$scratch/build/arch-install/"user-install-backup-*/"$module/marker")
[[ ${#saved_wallpaper[@]} == 1 && -f ${saved_wallpaper[0]} ]]
[[ ${#saved_module[@]} == 1 && -f ${saved_module[0]} ]]
grep -qx -- '--user restart plasma-plasmashell.service' "$TEST_LOG"
# Existing package, no local shadows: repeat safely without creating more backups.
backup_count=$(find "$scratch/build/arch-install" -name 'user-install-backup-*' | wc -l)
run 0
[[ $(find "$scratch/build/arch-install" -name 'user-install-backup-*' | wc -l) == "$backup_count" ]]
# Host pacman/sudo unavailable; only mocked package commands remain on PATH.
rm -f "$TEST_LOG.moves"
PATH="$scratch/bin" bash "$scratch/tools/scripts/install-arch.sh" > "$scratch/output" 2>&1
# Concurrent runs cannot overwrite PKGBUILD or migrate the same local install.
exec 8>"$scratch/build/arch-install/.lock"
flock -n 8
run 1
flock -u 8
# Inactive Plasma is harmless; a restart failure is reported after retaining backups.
TEST_SYSTEMCTL_RC=1 run 0
[[ -f ${saved_wallpaper[0]} && -f ${saved_module[0]} ]]
# Broken local symlinks also shadow system files and must be preserved.
ln -s "$scratch/missing" "$TEST_LOCAL/$module"
TEST_RESTART_RC=23 run 23
[[ ! -L $TEST_LOCAL/$module ]]
saved_links=("$scratch/build/arch-install/"user-install-backup-*/"$module")
found_link=0
for path in "${saved_links[@]}"; do
    [[ ! -L $path ]] || found_link=1
done
[[ $found_link == 1 ]]
# A failed rollback must retain the backup and identify its recovery path.
mkdir -p "$TEST_LOCAL/$wallpaper" "$TEST_LOCAL/$module"
touch "$TEST_LOCAL/$wallpaper/recovery" "$TEST_LOCAL/$module/recovery"
TEST_BACKUP_FAIL=2 TEST_ROLLBACK_FAIL=1 run 18
[[ ! -e $TEST_LOCAL/$wallpaper && -e $TEST_LOCAL/$module/recovery ]]
grep -q 'Restore failed: .*; restore manually to ' "$scratch/output"
recovery=("$scratch/build/arch-install/"user-install-backup-*/"$wallpaper/recovery")
[[ ${#recovery[@]} == 1 && -f ${recovery[0]} ]]
echo 'PASS: isolated package mocks, preserved revisions, failure rollback, backups, idempotency and locking.'
