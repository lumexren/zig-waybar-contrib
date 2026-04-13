#!/usr/bin/env bash
set -euo pipefail

# Configuration
REPO_URL="https://codeberg.org/erffy/zig-waybar-contrib"
BRANCH="0.16.x"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local}/share/zig-waybar-contrib"
BIN_DIR="${XDG_DATA_HOME:-$HOME/.local}/bin"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;36m'
YELLOW='\033[0;33m'
RESET='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${RESET} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${RESET} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $1" >&2; }

# banner
echo -e "${BLUE}"
echo "      _                               _                                      _        _ _     "
echo "  ___(_) __ _       _      ____ _ _  | |__   __ _ _ __       ___ ___  _ __ | |_ _ __(_) |__  "
echo " |_  / |/ _\` |_____| | /| / / _\` | | | '_ \ / _\` | '__|_____/ __/ _ \| '_ \| __| '__| | '_ \ "
echo "  / /| | (_| |_____| |/ |/ / (_| | |_| |_) | (_| | | |_____| (_| (_) | | | | |_| |  | | |_) |"
echo " /___|_|\__, |     |__/|__/ \__,_|\__,_|_.__/ \__,_|_|      \___\___/|_| |_|\__|_|  |_|_.__/ "
echo "        |___/                                                                                "
echo -e "${RESET}"

# 1. Check Dependencies
log_info "Checking dependencies..."
MISSING_DEPS=()
for dep in git zig; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        MISSING_DEPS+=("$dep")
    fi
done

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    log_error "Missing dependencies: ${MISSING_DEPS[*]}"
    log_info "Please install them using your package manager."
    exit 1
fi

# 2. Setup Directory & Repository
log_info "Setting up repository..."
if [ -d "$INSTALL_DIR" ]; then
    if [ -d "$INSTALL_DIR/.git" ]; then
        CURRENT_BRANCH=$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD)
        if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
             log_warn "Repository branch '$CURRENT_BRANCH' does not match expected '$BRANCH'. Recreating..."
             rm -rf "$INSTALL_DIR"
             git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
        else
            log_info "Updating existing repository at $INSTALL_DIR..."
            git -C "$INSTALL_DIR" fetch origin
            git -C "$INSTALL_DIR" reset --hard "origin/$BRANCH"
        fi
    else
        log_warn "Directory $INSTALL_DIR exists but is not a git repository. Recreating..."
        rm -rf "$INSTALL_DIR"
        git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
    fi
else
    log_info "Cloning repository to $INSTALL_DIR..."
    git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi

# 3. Build
log_info "Building project..."
cd "$INSTALL_DIR"
# Check if zig version is sufficient happens implicitly by build failing, 
# but we can try to be nice. For simplicity we just build.
if ! zig build -Drelease; then
    log_error "Build failed."
    exit 1
fi

# 4. Install Binaries
log_info "Installing binaries to $BIN_DIR..."
mkdir -p "$BIN_DIR"

INSTALLED_COUNT=0
# Zig build output is in zig-out/bin
if [ -d "zig-out/bin" ]; then
    for binary in zig-out/bin/*; do
        [ -f "$binary" ] || continue
        filename=$(basename "$binary")
        target_name="waybar-module-$filename"
        
        log_info "Installing $target_name..."
        cp -f "$binary" "$BIN_DIR/$target_name"
        INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
    done
fi

if [ "$INSTALLED_COUNT" -eq 0 ]; then
    log_error "No binaries found to install."
    exit 1
fi

# 5. Install Configuration
log_info "Installing configuration..."
if [ -f "config.waybar.jsonc" ]; then
    cp -r config.waybar.jsonc config.waybar.jsonc.source
    log_info "configuring config.waybar.jsonc with executable path: $BIN_DIR"
    sed "s|{{EXECUTABLE_PATH}}|$BIN_DIR|g" config.waybar.jsonc > "$INSTALL_DIR/config.waybar.jsonc"
    log_info "Configuration installed to $INSTALL_DIR/config.waybar.jsonc"
else
    log_warn "config.waybar.jsonc not found in repository. Skipping config installation."
fi

# 6. Verify PATH
log_success "Installation complete!"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    log_warn "$BIN_DIR is not in your PATH."
    log_info "Please add it to your shell configuration."
fi