#!/usr/bin/env bash
# Run as your desktop user. makepkg invokes sudo for dependency/package installation.
set -euo pipefail

if (( EUID == 0 )); then
    echo 'Run without sudo; makepkg builds as your user and uses sudo for pacman.' >&2
    exit 1
fi
for command in makepkg pacman git sudo flock; do
    command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work="$repo/build/arch-install"
mkdir -p "$work"
exec 9>"$work/.lock"
flock -n 9 || { echo 'Another installer is running.' >&2; exit 1; }
# Preserve initialized submodules, including locally committed renderer fixes.
# ponytail: missing modules need manual setup; add selective initialization for fresh clones.
submodules=$(git -C "$repo" submodule status --recursive)
if grep -q '^-' <<< "$submodules"; then
    echo 'Missing submodules. Run git submodule update --init --recursive, then retry.' >&2
    exit 1
fi
cp "$repo/arch/PKGBUILD" "$work/PKGBUILD"
version=$(git -C "$repo" describe --tags --long --dirty | sed -E 's/^v//; s/-([0-9]+)-g/.r\1.g/; s/-/./g')
printf '\npkgver=%q\n' "$version" >> "$work/PKGBUILD"

cd "$work"
WEK_REPO_ROOT="$repo" makepkg --syncdeps --install --force

# Roll back local migration failures; the pacman transaction is already complete.
backup=''
moved=()
rollback() {
    local relative path
    echo 'Local migration failed; package remains installed. Restoring local files.' >&2
    for relative in "${moved[@]}"; do
        path="$HOME/.local/$relative"
        if [[ -e "$path" || -L "$path" ]] || ! mv -T -- "$backup/$relative" "$path"; then
            echo "Restore failed: $backup/$relative; restore manually to $path" >&2
        fi
    done
}
trap rollback EXIT
trap 'exit 1' HUP INT TERM
module=com.github.captsilver.wallpaperEngineKde
for relative in "share/plasma/wallpapers/$module" \
                lib/qt6/qml/com/github/captsilver/wallpaperEngineKde; do
    path="$HOME/.local/$relative"
    if [[ -e "$path" || -L "$path" ]]; then
        if [[ -z "$backup" ]]; then
            backup=$(mktemp -d "$work/user-install-backup-XXXXXXXX")
        fi
        mkdir -p "$backup/$(dirname -- "$relative")"
        mv -T -- "$path" "$backup/$relative"
        moved+=("$relative")
    fi
done
trap - EXIT HUP INT TERM

echo "Installed package version: $version"
[[ -z "$backup" ]] || echo "Local-install backup: $backup"
if [[ -n ${XDG_RUNTIME_DIR:-} ]] && systemctl --user is-active --quiet plasma-plasmashell.service; then
    systemctl --user restart plasma-plasmashell.service
else
    echo 'Log out and back in to load the system installation.'
fi
