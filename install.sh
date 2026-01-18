#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# zig-waybar-contrib installation script
# Automates dependency checking, repository management, building, and installation
# ============================================================================

# Configuration
export SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
export BRANCH="0.16-dev"
export LOCAL_DIR="${XDG_DATA_HOME:-$HOME/.local}"
export BIN_DIR="$LOCAL_DIR/bin"
export ZWC_DIR="$LOCAL_DIR/share/zig-waybar-contrib"
export BUILD_FILE="$ZWC_DIR/build.zig.zon"
export REPO_URL="https://codeberg.org/erffy/zig-waybar-contrib"

# Dependencies
readonly -a DEPENDENCIES=(git zig)
readonly -a OPTIONAL_DEPENDENCIES=(gum)

# Color codes for fallback logging
readonly COLOR_RESET='\033[0m'
readonly COLOR_INFO='\033[0;36m'
readonly COLOR_WARN='\033[0;33m'
readonly COLOR_ERROR='\033[0;31m'

# Cache gum availability to avoid repeated lookups
HAS_GUM=false
command -v gum >/dev/null 2>&1 && HAS_GUM=true

# ============================================================================
# Logging & UI Functions
# ============================================================================

# Print a stylish banner
print_banner() {
    if [[ "$HAS_GUM" == true ]]; then
        gum style \
            --foreground 212 --border-foreground 212 --border double \
            --align center --width 50 --margin "1 2" --padding "2 4" \
            "zig-waybar-contrib" "Installation Script"
    else
        echo "=================================================="
        echo "           zig-waybar-contrib Setup"
        echo "=================================================="
        echo ""
    fi
}

# Run command with spinner if gum is available
run_with_spinner() {
    local title="$1"
    shift
    
    if [[ "$HAS_GUM" == true ]]; then
        # Quote arguments to preserve spaces/special chars for bash -c
        local cmd
        cmd=$(printf "%q " "$@")
        gum spin --spinner dot --title "$title" -- bash -c "$cmd"
    else
        log_info "$title..."
        "$@"
    fi
}

# Log informational message
log_info() {
    if [[ "$HAS_GUM" == true ]]; then
        gum log --structured --level info "$1"
    else
        echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $1" >&2
    fi
}

# Log warning message
log_warn() {
    if [[ "$HAS_GUM" == true ]]; then
        gum log --structured --level warn "$1"
    else
        echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $1" >&2
    fi
}

# Log error message
log_error() {
    if [[ "$HAS_GUM" == true ]]; then
        gum log --structured --level error "$1"
    else
        echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $1" >&2
    fi
}

# ============================================================================
# System Detection
# ============================================================================

# Detect Linux distribution
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "${ID:-unknown} ${ID_LIKE:-}"
    elif command -v lsb_release >/dev/null 2>&1; then
        lsb_release -si | tr '[:upper:]' '[:lower:]'
    else
        echo "unknown"
    fi
}

# Detect available privilege escalation method
detect_privilege_escalation() {
    local methods=(sudo-rs sudo doas run0 su)
    
    for method in "${methods[@]}"; do
        if command -v "$method" >/dev/null 2>&1; then
            echo "$method"
            return 0
        fi
    done
    
    # Check for su as last resort
    if command -v su >/dev/null 2>&1; then
        echo "su"
        return 0
    fi
    
    return 1
}

# Detect the system architecture and C library ABI
detect_arch_abi() {
    arch=$(uname -m)
    abi=$(ldd --version 2>&1 | grep -qi musl && echo musl || echo gnu)
    echo "${arch}-linux-${abi}"
}

# Detect cpu capabilities
detect_cpu_class() {
    local candidate=""
    if command -v gcc >/dev/null 2>&1; then
        candidate=$(gcc -march=native -Q --help=target 2>/dev/null | grep -Po "^\s*-march=\s+\K(\w+)$")
    fi

    if [ -n "$candidate" ] && command -v zig >/dev/null 2>&1; then
        if zig build -Dcpu=help 2>/dev/null | grep -qx "$candidate"; then
            echo "$candidate"
            return
        fi
    fi

    if [ -x /lib/ld-linux-x86-64.so.2 ]; then
        candidate=$(/lib/ld-linux-x86-64.so.2 --help | grep supported)

        if echo "$candidate" | grep -q "x86-64-v4"; then echo "x86_64_v4"
        elif echo "$candidate" | grep -q "x86-64-v3"; then echo "x86_64_v3"
        elif echo "$candidate" | grep -q "x86-64-v2"; then echo "x86_64_v2"
        else echo "x86_64"
        fi
        return
    fi

    echo "x86_64"
}

# Get package manager install command for distro
get_install_command() {
    local priv_esc="$1"
    shift
    local packages=("$@")
    
    local check_distros
    check_distros=$(detect_distro)
    
    if [[ "$check_distros" == "unknown" ]]; then
        log_error "Cannot determine distribution"
        return 1
    fi
    
    for distro in $check_distros; do
        case "$distro" in
            arch)
                echo "$priv_esc pacman -S --noconfirm ${packages[*]}"
                return 0
                ;;
            debian|ubuntu)
                echo "$priv_esc apt install -y ${packages[*]}"
                return 0
                ;;
            fedora|rhel)
                echo "$priv_esc dnf install -y ${packages[*]}"
                return 0
                ;;
            opensuse|suse)
                echo "$priv_esc zypper install -y ${packages[*]}"
                return 0
                ;;
            void)
                echo "$priv_esc xbps-install -Sy ${packages[*]}"
                return 0
                ;;
            alpine)
                echo "$priv_esc apk add ${packages[*]}"
                return 0
                ;;
            gentoo)
                echo "$priv_esc emerge ${packages[*]}"
                return 0
                ;;
        esac
    done
    
    # Special case for NixOS
    local distro_id=${check_distros%% *}
    if [[ "$distro_id" == "nixos" ]]; then
        log_warn "NixOS detected. Please install packages via configuration.nix or nix-env"
        return 1
    fi
    
    log_warn "Unsupported distribution: $check_distros"
    return 1
}

# ============================================================================
# Dependency Management
# ============================================================================

# Verify if dependencies are present (returns 0 if all present, 1 otherwise)
# Populates MISSING_DEPS global array
verify_dependencies() {
    local missing=()
    local optional_missing=()
    
    # Check required dependencies
    for dep in "${DEPENDENCIES[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    
    # Check optional dependencies
    for dep in "${OPTIONAL_DEPENDENCIES[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || optional_missing+=("$dep")
    done
    
    # Export missing deps to global scope for the installer
    MISSING_DEPS=("${missing[@]}")
    
    # Warn about optional dependencies
    [[ ${#optional_missing[@]} -gt 0 ]] && \
        log_warn "Optional dependencies not found: ${optional_missing[*]} (enhanced features disabled)"
        
    [[ ${#missing[@]} -eq 0 ]]
}

# Install missing dependencies interactively
install_dependencies() {
    local missing=("${MISSING_DEPS[@]}")
    
    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi
    
    log_error "Missing required dependencies: ${missing[*]}"
    
    # Detect system configuration
    local distro priv_esc install_cmd
    distro=$(detect_distro)
    
    if ! priv_esc=$(detect_privilege_escalation); then
        log_error "No privilege escalation method found (sudo, doas, su)"
        log_info "Please install dependencies manually and run this script again"
        return 1
    fi
    
    log_info "Detected distribution: $distro"
    log_info "Using privilege escalation: $priv_esc"
    
    # Get install command for this distro
    if ! install_cmd=$(get_install_command "$priv_esc" "${missing[@]}"); then
        log_error "Could not determine package installation command"
        log_info "Please install dependencies manually: ${missing[*]}"
        return 1
    fi
    
    # Offer automatic installation
    if [[ "$HAS_GUM" == true ]]; then
        if gum confirm "Install missing dependencies automatically?"; then
            log_info "Installing packages..."
            if eval "$install_cmd"; then
                log_info "Dependencies installed successfully"
                return 0
            else
                log_error "Failed to install dependencies"
                return 1
            fi
        else
            log_info "Installation cancelled by user"
            return 1
        fi
    else
        echo ""
        read -p "Install missing dependencies automatically? (y/N): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installing packages: ${missing[*]}"
            if eval "$install_cmd"; then
                log_info "Dependencies installed successfully"
                return 0
            else
                log_error "Failed to install dependencies"
                return 1
            fi
        else
            log_info "Installation cancelled by user"
            log_info "Please install manually: $install_cmd"
            return 1
        fi
    fi
}

# ============================================================================
# Repository Management
# ============================================================================

# Clone the repository from scratch
clone_repo() {
    if run_with_spinner "Cloning repository branch '$BRANCH'" git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$ZWC_DIR"; then
        log_info "Repository cloned successfully"
    else
        log_error "Failed to clone repository"
        return 1
    fi
}

# Update existing repository or clone if needed
# Returns: 0=successfully updated, 1=error, 2=already up-to-date
update_repo() {
    # Repository doesn't exist - clone it
    if [[ ! -d "$ZWC_DIR" ]]; then
        clone_repo
        return $?
    fi
    
    # Directory exists but isn't a git repo - re-clone
    if [[ ! -d "$ZWC_DIR/.git" ]]; then
        log_warn "Directory '$ZWC_DIR' exists but is not a git repository"
        log_info "Removing and re-cloning..."
        rm -rf "$ZWC_DIR"
        clone_repo
        return $?
    fi
    
    # Fetch updates
    log_info "Checking for updates..."
    if ! git -C "$ZWC_DIR" fetch origin "$BRANCH" 2>/dev/null; then
        log_error "Failed to fetch updates"
        return 1
    fi
    
    # Compare local and remote commits
    local local_hash remote_hash
    local_hash=$(git -C "$ZWC_DIR" rev-parse HEAD)
    remote_hash=$(git -C "$ZWC_DIR" rev-parse "origin/$BRANCH")
    
    if [[ "$local_hash" == "$remote_hash" ]]; then
        log_info "Repository is already up-to-date"
        return 2  # Special code for "already up-to-date"
    fi
    
    # Pull updates with fast-forward only
    if run_with_spinner "Pulling updates" git -C "$ZWC_DIR" pull --ff-only; then
        log_info "Repository updated successfully"
    else
        log_error "Failed to pull updates"
        return 1
    fi
}

# ============================================================================
# Version Management
# ============================================================================

# Extract minimum Zig version from build.zig.zon
read_min_zig_version() {
    [[ ! -f "$BUILD_FILE" ]] && {
        log_error "Build file not found: $BUILD_FILE"
        return 1
    }
    
    local version_line
    version_line=$(grep -Em1 '\.minimum_zig_version\s*=' "$BUILD_FILE")
    
    [[ -z "$version_line" ]] && {
        log_error "Could not find .minimum_zig_version in $BUILD_FILE"
        return 1
    }
    
    # Extract version string from quotes
    sed -E 's/.*"([^"]+)".*/\1/' <<< "$version_line"
}

# Compare two version strings (returns 0 if $1 >= $2)
version_compare() {
    local ver1="$1" ver2="$2"
    
    [[ "$ver1" == "$ver2" ]] && return 0
    
    # Use sort -V to compare versions semantically
    local sorted
    sorted=$(printf '%s\n%s' "$ver1" "$ver2" | sort -V | head -n1)
    
    [[ "$sorted" == "$ver2" ]]
}

# Verify installed Zig version meets minimum requirement
check_zig_version() {
    local min_version current_version
    
    min_version=$(read_min_zig_version) || return 1
    current_version=$(zig version 2>/dev/null) || {
        log_error "Failed to determine Zig version"
        return 1
    }
    
    if ! version_compare "$current_version" "$min_version"; then
        log_error "Zig version $current_version is below required $min_version"
        return 1
    fi
    
    log_info "Zig version $current_version meets minimum requirement ($min_version)"
}

# ============================================================================
# Build & Installation
# ============================================================================

# Build the project using Zig
build_project() {
    log_info "Starting build process..."
    
    cd "$ZWC_DIR" || {
        log_error "Failed to enter directory: $ZWC_DIR"
        return 1
    }
    
    local cpu_arch_abi=$(detect_arch_abi)
    local cpu_class=$(detect_cpu_class)

    if zig build -Dcpu=${cpu_class} -Dtarget=${cpu_arch_abi} -Doptimize=ReleaseFast; then
        log_info "Build completed successfully"
    else
        log_error "Zig build failed"
        return 1
    fi
}

# Check if binaries are already installed and up-to-date
check_binaries_installed() {
    local bin_dir="$ZWC_DIR/zig-out/bin"
    
    # 1. Check for uncommitted changes
    if [[ -n $(git -C "$ZWC_DIR" status --porcelain) ]]; then
        log_info "Local changes detected, rebuilding..."
        return 1
    fi
    
    # If build output doesn't exist, binaries aren't installed
    [[ ! -d "$bin_dir" ]] && return 1
    
    shopt -s nullglob
    local binaries=("$bin_dir"/*)
    shopt -u nullglob
    
    # No binaries built yet
    [[ ${#binaries[@]} -eq 0 ]] && return 1
    
    # 2. Get latest commit timestamp
    local commit_ts
    commit_ts=$(git -C "$ZWC_DIR" show -s --format=%ct HEAD)
    
    # 3. Check if all binaries are installed and newer than commit
    for binary in "${binaries[@]}"; do
        local base_name target_name installed_path
        base_name=$(basename "$binary")
        target_name="waybar-module-$base_name"
        installed_path="$BIN_DIR/$target_name"
        
        # Binary not installed
        [[ ! -f "$installed_path" ]] && return 1
        
        # Check if installed binary is older than the commit
        # Uses stat -c %Y for modification time (GNU stat)
        local binary_ts
        binary_ts=$(stat -c %Y "$installed_path" 2>/dev/null)
        
        if [[ "$binary_ts" -le "$commit_ts" ]]; then
            log_info "Binary $target_name is outdated"
            return 1
        fi
    done
    
    return 0
}

# Install built binaries to BIN_DIR with waybar-module- prefix
install_binaries() {
    local bin_dir="$ZWC_DIR/zig-out/bin"
    
    # Verify binaries exist
    shopt -s nullglob
    local binaries=("$bin_dir"/*)
    shopt -u nullglob
    
    if [[ ${#binaries[@]} -eq 0 ]]; then
        log_warn "No binaries found in $bin_dir"
        return 0
    fi
    
    log_info "Installing binaries to $BIN_DIR..."
    mkdir -p "$BIN_DIR"
    
    local installed_modules=()
    local failed_modules=()
    
    for binary in "${binaries[@]}"; do
        [[ ! -f "$binary" ]] && continue
        
        local base_name target_name module_name
        base_name=$(basename "$binary")
        target_name="waybar-module-$base_name"
        module_name="$base_name" # e.g., 'cpu' from 'waybar-module-cpu' if built that way, but here base_name IS 'cpu' usually
        
        # Build installation command
        if cp "$binary" "$BIN_DIR/$target_name" && chmod +x "$BIN_DIR/$target_name"; then
            installed_modules+=("$module_name")
        else
            failed_modules+=("$module_name")
        fi
    done
    
    if [[ ${#installed_modules[@]} -gt 0 ]]; then
        log_info "Installed modules: ${installed_modules[*]}"
    fi
    
    if [[ ${#failed_modules[@]} -gt 0 ]]; then
        log_warn "Not installed: ${failed_modules[*]}"
    fi
    
    if [[ ${#installed_modules[@]} -eq 0 ]]; then
        log_error "No binaries were installed"
        return 1
    fi
    
    # Verify BIN_DIR is in PATH
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        log_warn "$BIN_DIR is not in your PATH"
        log_info "Add to your shell config: export PATH=\"\$PATH:$BIN_DIR\""
    fi
}

# ============================================================================
# Cleanup & Main
# ============================================================================

# Cleanup handler for exit
cleanup() {
    local exit_code=$?
    [[ $exit_code -ne 0 ]] && log_error "Setup failed with exit code $exit_code"
    return "$exit_code"
}

trap cleanup EXIT

# Display usage information
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Setup script for zig-waybar-contrib modules.

Options:
    -h, --help      Show this help message
    -c, --clean     Remove existing repository before setup

Description:
    This script automates the setup of zig-waybar-contrib by:
    1. Checking required dependencies
    2. Cloning/updating the repository
    3. Verifying Zig version compatibility
    4. Building the project
    5. Installing binaries to $BIN_DIR

EOF
}

# Export functions used in spinners so subshells can see them
export -f verify_dependencies
export -f check_binaries_installed
export -f check_zig_version
export -f read_min_zig_version
export -f version_compare
export -f log_error
export -f log_info
export -f log_warn

# Main entry point
main() {
    local clean_install=false
    
    # Parse command-line arguments using getopt
    local PARSED_ARGUMENTS
    if ! PARSED_ARGUMENTS=$(getopt -o hc --long help,clean -n "$SCRIPT_NAME" -- "$@"); then
        usage
        exit 1
    fi
    
    eval set -- "$PARSED_ARGUMENTS"
    
    while true; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -c|--clean)
                clean_install=true
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                log_error "Unexpected option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    print_banner
    
    # Perform clean install if requested
    if [[ "$clean_install" == true && -d "$ZWC_DIR" ]]; then
        log_info "Performing clean install..."
        rm -rf "$ZWC_DIR"
    fi
    
    # 1. Dependency Check
    # We separate verification from installation to allow spinner usage
    MISSING_DEPS=()
    log_info "Checking dependencies..."
    if ! verify_dependencies; then
        install_dependencies || exit 1
    else
        log_info "All dependencies satisfied"
    fi
    
    # 2. Repository Updates
    local repo_status=0
    update_repo || repo_status=$?
    
    if [[ $repo_status -eq 1 ]]; then
        exit 1
    fi
    
    # 3. Up-to-date Check
    if [[ $repo_status -eq 2 ]]; then
        if run_with_spinner "Checking installed binaries" check_binaries_installed; then
            log_info "Setup is already up-to-date!"
            log_info "Use --clean to force reinstallation"
            exit 0
        else
            log_info "Binaries need to be built or updated"
        fi
    fi
    
    # 4. Zig Version Check
    run_with_spinner "Verifying Zig version" check_zig_version || exit 1
    
    # 5. Build & Install
    build_project || exit 1
    install_binaries || exit 1
    
    log_info "Setup completed successfully!"
    log_info "Binaries installed with prefix: waybar-module-"
    exit 0
}

main "$@"