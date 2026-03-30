#!/usr/bin/env bash
set -euo pipefail

########################################################################
# install_all_for_ps3.sh
#
# Installs all software needed for PS3:
#   1. plotutils (via system package manager)
#   2. FLINT 3.1.0 (built from source)
#   3. PPLite 0.12 (built from source)
#   4. PHAVerLite 0.7 (built from source)
#
# Prerequisites (must already be installed):
#   - C/C++ compiler supporting C++17 (g++ or clang++)
#   - GNU Make
#   - GMP and MPFR development libraries
#   - wget or curl (at least one)
#
# On Ubuntu/Debian:
#   sudo apt-get install build-essential libgmp-dev libmpfr-dev plotutils
#
# On macOS (Homebrew):
#   brew install gmp mpfr plotutils
########################################################################

# ── Usage / uninstall mode ────────────────────────────────────────────
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Usage: $0 [--uninstall [PREFIX]]"
    echo ""
    echo "  (no args)            Build and install FLINT, PPLite, PHAVerLite"
    echo "  --uninstall [PREFIX] Remove installed files (default PREFIX: ~/.local)"
    exit 0
fi

if [ "${1:-}" = "--uninstall" ]; then
    DEFAULT_PREFIX="$HOME/.local"
    PREFIX="${2:-}"

    if [ -z "$PREFIX" ]; then
        read -rp "Installation path to uninstall from [${DEFAULT_PREFIX}]: " PREFIX
        PREFIX="${PREFIX:-$DEFAULT_PREFIX}"
    fi
    PREFIX="${PREFIX/#\~/$HOME}"

    # Safety: refuse to uninstall from system-critical directories
    case "$PREFIX" in
        /|/usr|/usr/local|/bin|/sbin|/lib|/etc|/var|/opt|/System|/Applications)
            echo "ERROR: Refusing to uninstall from system directory '${PREFIX}'." >&2
            exit 1
            ;;
    esac

    MANIFEST="$PREFIX/.phaverlite_manifest"
    if [ -f "$MANIFEST" ]; then
        echo ""
        echo "The following files will be removed:"
        while IFS= read -r f; do
            case "$f" in
                "${PREFIX}"/*) [ -f "$f" ] && echo "  $f" ;;
                *)             echo "  [SKIP - outside prefix] $f" ;;
            esac
        done < "$MANIFEST"
        echo ""
        read -rp "Proceed with uninstall? [y/N]: " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
            echo "Uninstall cancelled."
            exit 0
        fi
        echo ""
        echo "Removing files..."
        while IFS= read -r f; do
            # Guard against path traversal: only remove files under PREFIX
            case "$f" in
                "${PREFIX}"/*)
                    if [ -f "$f" ]; then
                        rm -f "$f"
                        echo "  removed $f"
                    fi
                    ;;
                *)
                    echo "  skipped (outside prefix): $f"
                    ;;
            esac
        done < "$MANIFEST"
        rm -f "$MANIFEST"
    else
        echo "No manifest found at ${MANIFEST}."
        echo "Falling back to removing known installed components."
        echo ""
        echo "The following paths will be removed (if they exist):"
        for b in phaverlite phaverlite_static flint; do
            [ -f "$PREFIX/bin/$b" ] && echo "  $PREFIX/bin/$b"
        done
        for f in "$PREFIX"/lib/libflint* "$PREFIX"/lib/libpplite*; do
            [ -f "$f" ] && echo "  $f"
        done
        [ -d "$PREFIX/include/flint" ]  && echo "  $PREFIX/include/flint/"
        [ -d "$PREFIX/include/pplite" ] && echo "  $PREFIX/include/pplite/"
        [ -f "$PREFIX/lib/pkgconfig/flint.pc" ]  && echo "  $PREFIX/lib/pkgconfig/flint.pc"
        [ -f "$PREFIX/lib/pkgconfig/pplite.pc" ] && echo "  $PREFIX/lib/pkgconfig/pplite.pc"
        [ -f "$PREFIX/share/osc_demo.pha" ]      && echo "  $PREFIX/share/osc_demo.pha"
        echo ""
        read -rp "Proceed with uninstall? [y/N]: " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
            echo "Uninstall cancelled."
            exit 0
        fi
        echo ""
        echo "Removing files..."
        for b in phaverlite phaverlite_static flint; do
            rm -f "$PREFIX/bin/$b"
        done
        rm -f "$PREFIX"/lib/libflint*
        rm -f "$PREFIX"/lib/libpplite*
        rm -rf "$PREFIX"/include/flint
        rm -rf "$PREFIX"/include/pplite
        rm -f "$PREFIX"/lib/pkgconfig/flint.pc
        rm -f "$PREFIX"/lib/pkgconfig/pplite.pc
        rm -f "$PREFIX/share/osc_demo.pha"
    fi

    # Only remove component-specific subdirectories owned by this script.
    # Never remove shared directories (bin/, lib/, include/, share/, PREFIX itself)
    # since other software may use them.
    rmdir "$PREFIX"/include/flint 2>/dev/null || true
    rmdir "$PREFIX"/include/pplite 2>/dev/null || true

    echo ""
    echo "Uninstall complete."
    exit 0
fi

FLINT_VERSION="3.1.0"
PPLITE_VERSION="0.12"
PHAVERLITE_VERSION="0.7"

FLINT_URL="https://www.flintlib.org/download/flint-${FLINT_VERSION}.tar.gz"
PPLITE_URL="https://github.com/ezaffanella/PPLite/raw/main/releases/pplite-${PPLITE_VERSION}.tar.gz"
PHAVERLITE_URL="https://github.com/ezaffanella/PHAVerLite/raw/main/releases/phaverlite-${PHAVERLITE_VERSION}.tar.gz"

NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)

# ── Detect platform ──────────────────────────────────────────────────
OS="$(uname -s)"
case "$OS" in
    Linux)  PLATFORM="linux" ;;
    Darwin) PLATFORM="macos" ;;
    *)
        echo "ERROR: Unsupported platform '${OS}'. This script supports Linux and macOS only." >&2
        exit 1
        ;;
esac
echo "Detected platform: ${PLATFORM}"

# ── Check and install prerequisites ──────────────────────────────────
MISSING=()

check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        MISSING+=("$1")
        return 1
    fi
    return 0
}

# Check for a C++ compiler with C++17 support
CXX_FOUND=false
CXX17_OK=false
for cxx in g++ clang++; do
    if command -v "$cxx" &>/dev/null; then
        CXX_FOUND=true
        # Test C++17 support
        if echo 'int main() { if constexpr(true) {} return 0; }' | "$cxx" -std=c++17 -x c++ - -o /dev/null 2>/dev/null; then
            CXX17_OK=true
        fi
        break
    fi
done
if ! $CXX_FOUND; then
    MISSING+=("c++ compiler")
elif ! $CXX17_OK; then
    echo ""
    echo "WARNING: Found $cxx but it does not support C++17."
    if [ "$PLATFORM" = "macos" ]; then
        echo ""
        echo "Install or update Xcode Command Line Tools:"
        echo "  xcode-select --install"
        echo ""
        echo "After the installation finishes, re-run this script."
        echo ""
        read -rp "Run 'xcode-select --install' now? [Y/n]: " CXX_FIX
        CXX_FIX="${CXX_FIX:-Y}"
        if [[ "$CXX_FIX" =~ ^[Yy] ]]; then
            xcode-select --install 2>&1 || true
            echo ""
            echo "Xcode Command Line Tools installer launched."
            echo "Please wait for it to finish, then re-run this script."
        fi
        exit 1
    else
        echo ""
        if [ "$(id -u)" -eq 0 ]; then
            echo "  apt-get install g++-12"
        else
            echo "  sudo apt-get install g++-12"
        fi
        echo ""
        read -rp "Install g++-12 now? [Y/n]: " CXX_FIX
        CXX_FIX="${CXX_FIX:-Y}"
        if [[ "$CXX_FIX" =~ ^[Yy] ]]; then
            if [ "$(id -u)" -eq 0 ]; then
                apt-get update && apt-get install -y g++-12
            else
                sudo apt-get update && sudo apt-get install -y g++-12
            fi
            export CXX="g++-12"
            echo "Using g++-12."
        else
            echo "Please install a C++17 compiler and re-run this script."
            exit 1
        fi
    fi
fi

check_cmd make      || true
check_cmd graph     || true   # from plotutils

# Check for GMP and MPFR headers
GMP_OK=false
MPFR_OK=false

if [ "$PLATFORM" = "macos" ]; then
    # On macOS with Homebrew, check common locations
    for dir in /opt/homebrew/include /usr/local/include; do
        [ -f "$dir/gmp.h" ] && GMP_OK=true
        [ -f "$dir/mpfr.h" ] && MPFR_OK=true
    done
else
    # On Linux, check standard paths and use dpkg if available
    if [ -f /usr/include/gmp.h ] || [ -f /usr/local/include/gmp.h ]; then
        GMP_OK=true
    elif command -v dpkg &>/dev/null && dpkg -s libgmp-dev &>/dev/null 2>&1; then
        GMP_OK=true
    fi
    if [ -f /usr/include/mpfr.h ] || [ -f /usr/local/include/mpfr.h ]; then
        MPFR_OK=true
    elif command -v dpkg &>/dev/null && dpkg -s libmpfr-dev &>/dev/null 2>&1; then
        MPFR_OK=true
    fi
fi
$GMP_OK  || MISSING+=("gmp")
$MPFR_OK || MISSING+=("mpfr")

# Check for wget or curl (at least one is needed)
DOWNLOADER_OK=false
command -v wget &>/dev/null && DOWNLOADER_OK=true
command -v curl &>/dev/null && DOWNLOADER_OK=true
$DOWNLOADER_OK || MISSING+=("wget or curl")

if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    echo "Missing prerequisites: ${MISSING[*]}"
    echo ""

    # Build a platform-specific install command for only the missing packages
    PKGS=()
    if [ "$PLATFORM" = "macos" ]; then
        if ! command -v brew &>/dev/null; then
            echo "Homebrew is not installed. Install it first:"
            echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
            echo ""
            echo "Then re-run this script."
            exit 1
        fi
        for item in "${MISSING[@]}"; do
            case "$item" in
                "c++ compiler") PKGS+=("gcc") ;;
                "wget or curl") PKGS+=("curl") ;;
                graph)          PKGS+=("plotutils") ;;
                *)              PKGS+=("$item") ;;
            esac
        done
        echo "Install them with Homebrew:"
    else
        for item in "${MISSING[@]}"; do
            case "$item" in
                "c++ compiler") PKGS+=("build-essential") ;;
                make)           PKGS+=("build-essential") ;;
                gmp)            PKGS+=("libgmp-dev") ;;
                mpfr)           PKGS+=("libmpfr-dev") ;;
                "wget or curl") PKGS+=("curl") ;;
                graph)          PKGS+=("plotutils") ;;
                *)              PKGS+=("$item") ;;
            esac
        done
        # Deduplicate
        PKGS=($(printf '%s\n' "${PKGS[@]}" | sort -u))
        echo "Install them with apt (Ubuntu/Debian):"
    fi
    if [ "$PLATFORM" = "macos" ]; then
        echo "  brew install ${PKGS[*]}"
    else
        if [ "$(id -u)" -eq 0 ]; then
            echo "  apt-get install -y ${PKGS[*]}"
        else
            echo "  sudo apt-get install -y ${PKGS[*]}"
        fi
    fi

    echo ""
    read -rp "Would you like this script to install them now? [Y/n]: " INSTALL_ANSWER
    INSTALL_ANSWER="${INSTALL_ANSWER:-Y}"

    if [[ "$INSTALL_ANSWER" =~ ^[Yy] ]]; then
        echo "Installing prerequisites..."
        if [ "$PLATFORM" = "macos" ]; then
            brew install "${PKGS[@]}"
        elif [ "$(id -u)" -eq 0 ]; then
            apt-get update && apt-get install -y "${PKGS[@]}"
        else
            sudo apt-get update && sudo apt-get install -y "${PKGS[@]}"
        fi
        echo "Prerequisites installed."
        echo ""
    else
        echo "Please install the missing prerequisites and re-run this script."
        exit 1
    fi
else
    echo "All prerequisites found."
fi
echo ""

# ── Prompt for installation prefix ────────────────────────────────────
DEFAULT_PREFIX="$HOME/.local"
read -rp "Installation path [${DEFAULT_PREFIX}]: " PREFIX
PREFIX="${PREFIX:-$DEFAULT_PREFIX}"

# Expand ~ if the user typed it literally
PREFIX="${PREFIX/#\~/$HOME}"

# Make it an absolute path
PREFIX="$(cd "$(dirname "$PREFIX")" 2>/dev/null && pwd)/$(basename "$PREFIX")" || PREFIX="$(realpath -m "$PREFIX" 2>/dev/null || echo "$PREFIX")"

echo ""
echo "Will install to: ${PREFIX}"
echo ""
echo "The following directories will be created/written to:"
echo "  ${PREFIX}/bin/            -- phaverlite, phaverlite_static"
echo "  ${PREFIX}/lib/            -- libflint, libpplite"
echo "  ${PREFIX}/include/flint/  -- FLINT headers"
echo "  ${PREFIX}/include/pplite/ -- PPLite headers"
echo "  ${PREFIX}/lib/pkgconfig/  -- flint.pc, pplite.pc"
echo "  ${PREFIX}/share/          -- osc_demo.pha"
echo ""
read -rp "Proceed with installation? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    echo "Installation cancelled."
    exit 0
fi
echo ""

# Create the prefix directory (and standard sub-dirs) if needed
if [ ! -d "$PREFIX" ]; then
    echo "Directory ${PREFIX} does not exist. Creating it..."
    mkdir -p "$PREFIX"
fi
mkdir -p "$PREFIX"/{bin,lib,include,share}

# ── Set up environment so later builds find earlier ones ──────────────
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CPPFLAGS="-I$PREFIX/include ${CPPFLAGS:-}"
export LDFLAGS="-L$PREFIX/lib ${LDFLAGS:-}"

if [ "$PLATFORM" = "macos" ]; then
    export DYLD_LIBRARY_PATH="$PREFIX/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    # Homebrew puts GMP/MPFR in versioned paths; help the compiler find them
    for pkg in gmp mpfr; do
        BREW_PREFIX="$(brew --prefix "$pkg" 2>/dev/null || true)"
        if [ -n "$BREW_PREFIX" ] && [ -d "$BREW_PREFIX" ]; then
            export CPPFLAGS="-I${BREW_PREFIX}/include ${CPPFLAGS}"
            export LDFLAGS="-L${BREW_PREFIX}/lib ${LDFLAGS}"
        fi
    done
else
    export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# ── Known checksums for download verification ────────────────────────
# SHA-256 hashes of the expected release tarballs
get_checksum() {
    case "$1" in
        "flint-${FLINT_VERSION}.tar.gz")      echo "4b107e51b87738c334125b9dbbc11a0e3b146199b2decfc6a62d52c2453a3341" ;;
        "pplite-${PPLITE_VERSION}.tar.gz")     echo "f6aba554421944f1d5e469d59a9eb99ccac6ad4c111a447c8bc3916cb7476f51" ;;
        "phaverlite-${PHAVERLITE_VERSION}.tar.gz") echo "4de2a80b11852b99590b35e3a8601b58c2612854585d5ca70ace82adf4026bb0" ;;
        *) echo "" ;;
    esac
}

# ── Helper: download a tarball ────────────────────────────────────────
download() {
    local url="$1" dest="$2"
    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "$dest" "$url"
    elif command -v curl &>/dev/null; then
        curl -fL -o "$dest" "$url"
    else
        echo "ERROR: Neither wget nor curl found. Please install one." >&2
        exit 1
    fi
}

# ── Helper: verify checksum if known ─────────────────────────────────
verify_checksum() {
    local file="$1"
    local basename="${file##*/}"
    local expected
    expected="$(get_checksum "$basename")"

    if [ -z "$expected" ]; then
        echo "  (no checksum on record -- skipping verification)"
        return 0
    fi

    local actual
    if command -v sha256sum &>/dev/null; then
        actual="$(sha256sum "$file" | cut -d' ' -f1)"
    elif command -v shasum &>/dev/null; then
        actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
    else
        echo "  WARNING: No sha256sum or shasum found -- skipping verification"
        return 0
    fi

    if [ "$actual" != "$expected" ]; then
        echo "ERROR: Checksum mismatch for ${basename}!" >&2
        echo "  Expected: ${expected}" >&2
        echo "  Got:      ${actual}" >&2
        echo "  The downloaded file may be corrupted or tampered with." >&2
        exit 1
    fi
    echo "  Checksum verified."
}

# ── Create a temporary build area ─────────────────────────────────────
BUILD_DIR="$(mktemp -d)"
chmod 700 "$BUILD_DIR"
echo "Build directory: ${BUILD_DIR}"
echo ""
trap 'echo ""; echo "Build artifacts left in ${BUILD_DIR} for inspection."' EXIT

# ── 1. Build and install FLINT ────────────────────────────────────────
echo "============================================================"
echo " [1/3] FLINT ${FLINT_VERSION}"
echo "============================================================"
cd "$BUILD_DIR"
echo "Downloading FLINT..."
download "$FLINT_URL" "flint-${FLINT_VERSION}.tar.gz"
verify_checksum "flint-${FLINT_VERSION}.tar.gz"
tar xzf "flint-${FLINT_VERSION}.tar.gz"
cd "flint-${FLINT_VERSION}"

echo "Configuring FLINT..."
./configure --prefix="$PREFIX"
echo "Building FLINT (using ${NPROC} jobs)..."
make -j"$NPROC"
echo "Installing FLINT..."
find "$PREFIX" -type f | sort > "$BUILD_DIR/.pre_install" 2>/dev/null || true
make install
find "$PREFIX" -type f | sort > "$BUILD_DIR/.post_install" 2>/dev/null || true
comm -13 "$BUILD_DIR/.pre_install" "$BUILD_DIR/.post_install" >> "$PREFIX/.phaverlite_manifest"
echo "FLINT installed successfully."
echo ""

# ── 2. Build and install PPLite ───────────────────────────────────────
echo "============================================================"
echo " [2/3] PPLite ${PPLITE_VERSION}"
echo "============================================================"
cd "$BUILD_DIR"
echo "Downloading PPLite..."
download "$PPLITE_URL" "pplite-${PPLITE_VERSION}.tar.gz"
verify_checksum "pplite-${PPLITE_VERSION}.tar.gz"
tar xzf "pplite-${PPLITE_VERSION}.tar.gz"
cd "pplite-${PPLITE_VERSION}"

echo "Configuring PPLite..."
./configure --prefix="$PREFIX" \
    --with-flint="$PREFIX"
echo "Building PPLite (using ${NPROC} jobs)..."
make -j"$NPROC"
echo "Installing PPLite..."
find "$PREFIX" -type f | sort > "$BUILD_DIR/.pre_install" 2>/dev/null || true
make install
find "$PREFIX" -type f | sort > "$BUILD_DIR/.post_install" 2>/dev/null || true
comm -13 "$BUILD_DIR/.pre_install" "$BUILD_DIR/.post_install" >> "$PREFIX/.phaverlite_manifest"
echo "PPLite installed successfully."
echo ""

# ── 3. Build and install PHAVerLite ───────────────────────────────────
echo "============================================================"
echo " [3/3] PHAVerLite ${PHAVERLITE_VERSION}"
echo "============================================================"
cd "$BUILD_DIR"
echo "Downloading PHAVerLite..."
download "$PHAVERLITE_URL" "phaverlite-${PHAVERLITE_VERSION}.tar.gz"
verify_checksum "phaverlite-${PHAVERLITE_VERSION}.tar.gz"
tar xzf "phaverlite-${PHAVERLITE_VERSION}.tar.gz"
cd "phaverlite-${PHAVERLITE_VERSION}"

echo "Configuring PHAVerLite..."
./configure --prefix="$PREFIX" \
    --with-flint="$PREFIX" \
    --with-pplite="$PREFIX"
echo "Building PHAVerLite (using ${NPROC} jobs)..."
make -j"$NPROC"
echo "Installing PHAVerLite..."
find "$PREFIX" -type f | sort > "$BUILD_DIR/.pre_install" 2>/dev/null || true
make install
find "$PREFIX" -type f | sort > "$BUILD_DIR/.post_install" 2>/dev/null || true
comm -13 "$BUILD_DIR/.pre_install" "$BUILD_DIR/.post_install" >> "$PREFIX/.phaverlite_manifest"
echo "PHAVerLite installed successfully."
echo ""

# ── Done ──────────────────────────────────────────────────────────────
echo "============================================================"
echo " All components installed to: ${PREFIX}"
echo "============================================================"
echo ""


# Download the demo file
OSC_DEMO_URL="https://github.com/ezaffanella/PHAVerLite/raw/main/osc_demo.pha"
echo "Downloading demo file osc_demo.pha..."
download "$OSC_DEMO_URL" "$PREFIX/share/osc_demo.pha"
echo "$PREFIX/share/osc_demo.pha" >> "$PREFIX/.phaverlite_manifest"
echo ""

echo "============================================================"
echo ""
echo ""
echo ""
echo "To use phaverlite from any terminal, add the following lines"
echo "to your shell profile (e.g., ~/.bashrc or ~/.zshrc):"
echo ""

# Always suggest the PATH
echo "  export PATH=\"$PREFIX/bin:\$PATH\""

# Suggest the library path based on the platform
if [ "$PLATFORM" = "macos" ]; then
    echo "  export DYLD_LIBRARY_PATH=\"$PREFIX/lib:\${DYLD_LIBRARY_PATH:-}\""
else
    echo "  export LD_LIBRARY_PATH=\"$PREFIX/lib:\${LD_LIBRARY_PATH:-}\""
fi

echo ""
echo "After adding the lines, run 'source ~/.bashrc' (or ~/.zshrc)."
echo ""

echo "To test the installation, run:"
echo " ${PREFIX}/bin/phaverlite -v256001 ${PREFIX}/share/osc_demo.pha"
