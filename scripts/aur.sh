#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of zig-waybar-contrib.
#
# Copyright (c) 2026 erffy
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://gnu.org/licenses>.

set -euo pipefail

pacman -Sy --noconfirm sudo git openssh pacman-contrib

mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "$AUR_SSH_KEY" > /root/.ssh/id_ed25519
chmod 600 /root/.ssh/id_ed25519
ssh-keyscan aur.archlinux.org >> /root/.ssh/known_hosts

git config --global user.name "erffy"
git config --global user.email "$EMAIL"

cd aur/$AUR_REPO

BINARY_URL="${REPO_URL}/releases/download/${VERSION}/${RELEASE_FILENAME}"
CONFIG_URL="${REPO_URL}/raw/tag/${VERSION}/config.waybar.jsonc"
LICENSE_URL="${REPO_URL}/raw/tag/${VERSION}/LICENSE"

old_ver="$(grep "^pkgver=" PKGBUILD | cut -d= -f2 || printf "")"
old_rel="$(grep "^pkgrel=" PKGBUILD | cut -d= -f2 || printf "0")"
if [[ "$old_ver" == "$VERSION" ]]; then
	new_rel=$(( old_rel + 1 ))
else
	new_rel="1"
fi

sed -i "s|^pkgver=.*|pkgver=${VERSION}|" PKGBUILD
sed -i "s|^pkgrel=.*|pkgrel=$new_rel|" PKGBUILD
sed -i "s|BINARY_DOWNLOAD_URL|${BINARY_URL}|" PKGBUILD
sed -i "s|CONFIG_DOWNLOAD_URL|${CONFIG_URL}|" PKGBUILD
sed -i "s|LICENSE_DOWNLOAD_URL|${LICENSE_URL}|" PKGBUILD

curl -fsSL -o zig-waybar-contrib.zip "${REPO_URL}/releases/download/${VERSION}/${RELEASE_FILENAME}"
curl -fsSL -o config.waybar.jsonc "${REPO_URL}/raw/tag/${VERSION}/config.waybar.jsonc"
curl -fsSL -o LICENSE "${REPO_URL}/raw/tag/${VERSION}/LICENSE"

useradd -m builder
echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

chown -R builder .

sudo -u builder bash -c "updpkgsums && makepkg --printsrcinfo > .SRCINFO"

rm zig-waybar-contrib.zip config.waybar.jsonc LICENSE

cd ../..
git clone ssh://aur@aur.archlinux.org/${AUR_REPO}.git aur-repo

cp aur/$AUR_REPO/{PKGBUILD,.SRCINFO} aur-repo

cd aur-repo
git add PKGBUILD .SRCINFO

if git diff --cached --quiet; then
  echo "No changes detected, skipping push."
	exit 0
fi

git commit -m "release: update to ${VERSION}-${new_rel}"
git push origin master