#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════╗
# ║                     MP4 VAULT  v1.0.0                                ║
# ║        Cat-Append Steganography — Hide & Extract Files              ║
# ║        in Carrier Videos  |  Optional AES-256 Encryption            ║
# ╚══════════════════════════════════════════════════════════════════════╝

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  USER CONFIG  ──  Edit this block to customise default behaviour
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DEFAULT_SCAN_DIR=""         # Absolute path to default scan dir; blank = prompt
DEFAULT_OUTPUT_DIR=""       # Where outputs are saved; blank = current working directory
CONFIG_FILE="${HOME}/.mp4vault.conf"   # Persistent config file path
ENCRYPT_PAYLOAD=true        # true  → AES-256-CBC encrypt payload before hiding
SHOW_SIZES=true             # true  → display file sizes next to filenames
PAGE_SIZE=20                # Max files listed per page before pagination kicks in
VERBOSE=true               # true  → print extra diagnostic messages
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ── MINIMUM BASH VERSION CHECK ─────────────────────────────────────────
# local -n (nameref) requires bash 4.3+
if (( BASH_VERSINFO[0] < 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3 ) )); then
    echo "ERROR: bash 4.3 or later is required (found $BASH_VERSION)." >&2
    echo "  macOS users: brew install bash  then run with /usr/local/bin/bash $0" >&2
    exit 1
fi

# ── ANSI COLOURS ───────────────────────────────────────────────────────
cyan="\033[1;36m" blue="\033[1;34m"  ; green="\033[1;32m"  ; yellow="\033[1;33m"
red="\033[1;31m"   ; purple="\033[1;35m" ; white="\033[1;37m" ; magenta="\033[1;35m"
dim="\033[2m"      ; reset="\033[0m"  ;

# ── UI HELPERS ─────────────────────────────────────────────────────────
msg() {                               # msg <type> <message...>
    case "$1" in
        ok)    echo -e "${green}  ➜ ${*:2}${reset}" ;;
        warn)  echo -e "${yellow}    ⓘ ${*:2}${reset}" ;;
        warn2)  echo -e "${yellow}  ⓘ ${*:2}${reset}" ;;
        err)   echo -e "${red}  ⊘ ${*:2}${reset}"   ;;
        info)  echo -e "${blue}   (𝒊) ${*:2}${reset}"  ;;
        step)  echo -e "${purple} ⌯⌲ ${*:2}${reset}" ;;
        dbg)   $VERBOSE && echo -e "${dim}  ❯ ${*:2}${reset}" ;;
    esac
}
gap()     { echo; }
divider() { echo -e "${dim}  ──────────────────────────────────────────────────${reset}"; }
section() { gap; divider; echo -e "  ${white}${1}${reset}"; gap; }

# ── PORTABLE TEMP DIRECTORY ────────────────────────────────────────────
# Android/Termux does not allow writing to /tmp without root.
# Resolution order: $TMPDIR env var (set by Termux) → /tmp → ~/tmp → script dir
_resolve_tmpdir() {
    local candidates=("${TMPDIR:-}" "/tmp" "$HOME/tmp" "$(dirname "$(realpath "$0")")/tmp")
    for _d in "${candidates[@]}"; do
        [[ -z "$_d" ]] && continue
        mkdir -p "$_d" 2>/dev/null
        if [[ -d "$_d" && -w "$_d" ]]; then
            echo "$_d"; return 0
        fi
    done
    # Last resort: current working directory
    echo "."
}
VAULT_TMPDIR="$(_resolve_tmpdir)"

# ── TEMP FILE TRACKING ─────────────────────────────────────────────────
TEMP_ENC=""
ACTIVE_OUTPUT=""
INTERRUPTED=0

# Always fires on any exit — removes leftover temp files silently
_cleanup() {
    [[ -n "$TEMP_ENC"      ]] && rm -f "$TEMP_ENC"
    [[ -n "$ACTIVE_OUTPUT" ]] && rm -f "$ACTIVE_OUTPUT"
}

# Only fires on Ctrl+C / kill — prints the user-facing "interrupted" line
_int_handler() {
    INTERRUPTED=1
    [[ -n "$pid"      ]] && kill "$pid"      2>/dev/null
    [[ -n "$_dec_pid" ]] && kill "$_dec_pid" 2>/dev/null
    [[ -n "$_enc_pid" ]] && kill "$_enc_pid" 2>/dev/null
    gap
    msg warn2 "Interrupted — temp files cleaned up."
    exit 130
}

trap '_cleanup'     EXIT       # handles ALL exits, including normal ones
trap '_int_handler' INT TERM   # signals → print message → exit → triggers EXIT

# ── CONFIG PERSISTENCE ─────────────────────────────────────────────────
_load_config() {
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
}

_save_config() {
    cat > "$CONFIG_FILE" <<EOF
DEFAULT_SCAN_DIR="$DEFAULT_SCAN_DIR"
DEFAULT_OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
EOF
}

_load_config   # Load saved defaults on every run

# ── STARTUP TOOL CHECK ─────────────────────────────────────────────────
# Checks for required and recommended tools, auto-installs via the
# detected package manager (apt/pkg/pacman/dnf/brew), and sets the
# USE_FIGLET / USE_OPENSSL capability flags used throughout the script.
_startup_check() {
    # tool → package name (same names work across apt, pkg, pacman, dnf, brew)
    declare -A _pkg=(
        [file]="file"       [realpath]="coreutils"  [awk]="gawk"
        [openssl]="openssl-tool" [figlet]="figlet"
    )
    local _required=(file realpath awk openssl figlet)

    # ── Detect package manager & whether sudo is needed ────────────────
    local _pm="" _pm_upg="" _pm_inst="" _sudo=""

    # Only prepend sudo when not already root and sudo is available
    if [[ "$(id -u)" -ne 0 ]] && command -v sudo &>/dev/null; then
        _sudo="sudo "
    fi

    # Termux detection: $PREFIX is set and pkg/apt are available without root
    if [[ -n "${TERMUX_VERSION:-}" ]] || [[ -n "${PREFIX:-}" && -d "${PREFIX}/bin" ]]; then
        if command -v pkg &>/dev/null; then
            _pm="pkg"
            _pm_upg="pkg update -y && pkg upgrade -y"
            _pm_inst="pkg install -y"
            _sudo=""          # Termux never needs sudo
        elif command -v apt &>/dev/null; then
            _pm="apt"
            _pm_upg="apt update && apt upgrade -y"
            _pm_inst="apt install -y"
            _sudo=""
        fi
    fi

    # Generic Linux / macOS fallbacks
    if [[ -z "$_pm" ]]; then
        if   command -v apt    &>/dev/null; then
            _pm="apt";    _pm_upg="${_sudo}apt update && ${_sudo}apt upgrade -y"
            _pm_inst="${_sudo}apt install -y"
        elif command -v pacman &>/dev/null; then
            _pm="pacman"; _pm_upg="${_sudo}pacman -Syu --noconfirm"
            _pm_inst="${_sudo}pacman -S --noconfirm"
        elif command -v dnf    &>/dev/null; then
            _pm="dnf";    _pm_upg="${_sudo}dnf update -y"
            _pm_inst="${_sudo}dnf install -y"
        elif command -v yum    &>/dev/null; then
            _pm="yum";    _pm_upg="${_sudo}yum update -y"
            _pm_inst="${_sudo}yum install -y"
        elif command -v brew   &>/dev/null; then
            _pm="brew";   _pm_upg="brew update && brew upgrade"
            _pm_inst="brew install"   # brew never needs sudo
        fi
    fi

    # B6: "openssl-tool" is Termux's pkg name; every other package manager calls it "openssl"
    [[ "$_pm" != "pkg" ]] && _pkg[openssl]="openssl"

    # ── Check which tools are missing ──────────────────────────────────
    local _miss_req=() _miss_rec=()
    for _t in "${_required[@]}";    do command -v "$_t" &>/dev/null || _miss_req+=("$_t"); done
    for _t in "${_recommended[@]}"; do command -v "$_t" &>/dev/null || _miss_rec+=("$_t"); done

    section "🔧 Tool Check"

    if (( ${#_miss_req[@]} == 0 && ${#_miss_rec[@]} == 0 )); then
        msg ok "All tools present — nothing to install."

    else
        (( ${#_miss_req[@]} > 0 )) && msg warn "Missing required:    ${_miss_req[*]}"
        (( ${#_miss_rec[@]} > 0 )) && msg info "Missing recommended: ${_miss_rec[*]}"
        gap

        # ── No package manager available ───────────────────────────────
        if [[ -z "$_pm" ]]; then
            if (( ${#_miss_req[@]} > 0 )); then
                msg err "No supported package manager found."
                msg info "Install manually: ${_miss_req[*]}"
                exit 1
            fi
            msg warn2 "No package manager found — skipping optional installs."

        else
            echo -e "  ${dim}Package manager detected: ${_pm}${reset}"
            local _did_update=false

            # ── Prompt 1: required tools ────────────────────────────────
            if (( ${#_miss_req[@]} > 0 )); then
                gap
                read -rp "  ➤ Install required tools? (Y/n): " _raw
               if [[ -z "${_raw}" || "${_raw,,}" == "y" ]]; then
                    gap
                    msg step "Updating & upgrading packages…"
                    eval "$_pm_upg" || msg warn2 "Update step had non-zero exit — continuing."
                    _did_update=true
                    gap

                    local _req_pkgs=()
                    for _t in "${_miss_req[@]}"; do
                        _req_pkgs+=("${_pkg[$_t]:-$_t}")
                    done
                    msg step "Installing required: ${_req_pkgs[*]}"
                    eval "$_pm_inst ${_req_pkgs[*]}" || msg warn2 "Installer had non-zero exit — re-checking."

                    # Re-verify every required tool is now present
                    local _still=()
                    for _t in "${_miss_req[@]}"; do
                        command -v "$_t" &>/dev/null || _still+=("$_t")
                    done
                    if (( ${#_still[@]} > 0 )); then
                        msg err "Still missing after install: ${_still[*]}"
                        msg info "Try installing them manually and re-run."
                        exit 1
                    fi
                    msg ok "Required tools installed successfully."
                else
                    msg err "Required tools missing — cannot continue."; exit 1
                fi
            fi

            # ── Prompt 2: recommended tools (separate, always asked) ────
            if (( ${#_miss_rec[@]} > 0 )); then
                gap
                read -rp "  ➤ Install recommended tools? (Y/n): " _raw
                if [[ -z "${_raw}" || "${_raw,,}" == "y" ]]; then
                    if ! $_did_update; then
                        gap
                        msg step "Updating & upgrading packages…"
                        eval "$_pm_upg" || msg warn2 "Update step had non-zero exit — continuing."
                        _did_update=true
                        gap
                    fi

                    local _rec_pkgs=()
                    for _t in "${_miss_rec[@]}"; do
                        _rec_pkgs+=("${_pkg[$_t]:-$_t}")
                    done
                    msg step "Installing recommended: ${_rec_pkgs[*]}"
                    eval "$_pm_inst ${_rec_pkgs[*]}" || msg warn2 "Installer had non-zero exit — continuing."
                    msg ok "Recommended tools installed."
                else
                    msg warn2 "Skipping recommended tools — some features may be unavailable."
                fi
            fi
        fi
    fi

    # ── Set capability flags used throughout the script ─────────────────
    USE_FIGLET=false  ; command -v figlet  &>/dev/null && USE_FIGLET=true
    USE_OPENSSL=false ; command -v openssl &>/dev/null && USE_OPENSSL=true
}

_startup_check

# ── TERMUX SYSTEM-WIDE INSTALL ─────────────────────────────────────────
# Offers a one-time prompt to copy vvault into $PREFIX/bin so it can be
# launched by name from any directory.  Only shown inside Termux and only
# when the script is NOT already running from $PREFIX/bin.
_install_termux_systemwide() {
    # Abort immediately if we are not inside Termux
    if [[ -z "${TERMUX_VERSION:-}" ]] && \
       [[ -z "${PREFIX:-}" || ! -d "${PREFIX}/bin" ]]; then
        return 0
    fi

    local _install_name="mp4vault"
    local _install_target="${PREFIX}/bin/${_install_name}"

    # Already running from the system bin — nothing to do
    local _self
    _self="$(realpath "$0" 2>/dev/null || echo "$0")"
    if [[ "$_self" == "$_install_target" ]]; then
        return 0
    fi

    section "📦 Install System-Wide (Termux)"
    echo -e "  ${dim}Copy mp4vault to \$PREFIX/bin so you can launch it from any folder.${reset}"
    echo -e "  ${dim}Target: ${_install_target}${reset}"
    gap
    echo -e "  ${blue}[1]${reset}  Install now   ${dim}(enables: mp4vault)${reset}"
    echo -e "  ${blue}[2]${reset}  Skip for now"
    gap
    while true; do
        read -rp "  ➤ Choice: " _raw
        local _ic; _ic="$(trim "$_raw")"
        case "$_ic" in
            1)
                if cp "$_self" "$_install_target" 2>/dev/null && \
                   chmod +x "$_install_target" 2>/dev/null; then
                    msg ok "Installed → ${_install_target}"
                    msg info "From now on, type 'mp4vault' from any folder to launch MP4 VAULT."
                else
                    msg err "Installation failed — check file permissions."
                    msg info "Manual install:"
                    msg info "  cp \"$_self\" \"$_install_target\" && chmod +x \"$_install_target\""
                fi
                break
                ;;
            2)
                msg info "Skipped — re-run this script any time to install later."
                break
                ;;
            *) msg err "Invalid choice — enter 1 or 2." ;;
        esac
    done
}

# ── UTILITY FUNCTIONS ──────────────────────────────────────────────────

# Expand a leading ~ to $HOME (read does not do shell expansion)
expand_path() { echo "${1/#\~/$HOME}"; }

# Strip leading and trailing whitespace from input
trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    echo "$s"
}

# Returns 0 if $1 is an integer in [1, $2]
validate_choice() {
    local c="$1" m="$2"
    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= m ))
}

# Cross-platform file byte count: GNU stat vs BSD/macOS stat
get_bytes() {
    if stat --version 2>/dev/null | grep -q GNU; then
        stat -c%s "$1"
    else
        stat -f%z "$1"
    fi
}

# Convert raw bytes to a readable string (B / KB / MB / GB)
human_size() {
    awk -v b="$1" 'BEGIN {
        if      (b >= 1073741824) printf "%.1f GB", b/1073741824
        else if (b >= 1048576)    printf "%.1f MB", b/1048576
        else if (b >= 1024)       printf "%.1f KB", b/1024
        else                      printf "%d B",    b
    }'
}

# Check available disk space; warn and return 1 if insufficient
check_space() {
    local dir="$1" needed="$2"
    local avail
    avail=$(df -P "$dir" 2>/dev/null | awk 'NR==2 { print $4 * 1024 }')
    [[ -z "$avail" ]] && return 0          # can't determine — skip check silently
    if (( avail < needed )); then
        msg err "Not enough disk space in $dir"
        msg info "Need $(human_size "$needed") — available $(human_size "$avail")"
        return 1
    fi
}

# Returns 0 if $1 is a video, determined by MIME type (not filename/extension)
is_video() { file --mime-type "$1" 2>/dev/null | grep -q "video/"; }

# Returns 0 if the first argument appears in the remaining arguments
is_in_array() {
    local needle="$1"; shift
    local item
    for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
    return 1
}

# Print a numbered, paginated file list with optional sizes
# Usage: list_files <array_nameref> <icon_emoji>
list_files() {
    local -n _lf_arr="$1"
    local icon="$2"
    local total="${#_lf_arr[@]}"
    local page_start=0

    while true; do
        local page_end=$(( page_start + PAGE_SIZE ))
        (( page_end > total )) && page_end=$total

        local i
        for (( i = page_start; i < page_end; i++ )); do
            local f="${_lf_arr[$i]}"
            local label="${f##*/}"
            local sz_str=""
            if $SHOW_SIZES; then
                local sz; sz=$(get_bytes "$f" 2>/dev/null || echo 0)
                sz_str=$(human_size "$sz")
            fi
            printf "  ${blue}%3d${reset}  ${icon}  %-44s  ${dim}%s${reset}\n" \
                "$((i+1))" "$label" "$sz_str"
        done

        gap
        if (( page_end < total )); then
            echo -e "  ${dim}Showing $((page_start+1))–${page_end} of ${total}   [Enter = next page]${reset}"
            read -r _pg
            page_start=$page_end
        else
            break
        fi
    done
}

# Byte-accurate progress bar for file-producing jobs.
# Usage: show_file_progress <pid> <file> <expected_bytes> <color_escape> [width] [delay]
show_file_progress() {
    local _pid="$1"
    local _file="$2"
    local _expected="$3"
    local _color="$4"
    local _width="${5:-30}"
    local _delay="${6:-0.08}"
    local _progress=0
    local _size=0
    local _filled=0
    local _empty=0
    local _bar=""
    local _space=""
    local _exit_code=0

    while kill -0 "$_pid" 2>/dev/null; do
        _size=0
        [[ -e "$_file" ]] && _size=$(get_bytes "$_file" 2>/dev/null || echo 0)

        if (( _expected > 0 )); then
            _progress=$(( _size * 100 / _expected ))
            (( _progress > 99 )) && _progress=99
        else
            _progress=0
        fi

        _filled=$(( _progress * _width / 100 ))
        _empty=$(( _width - _filled ))
        _bar=""
        (( _filled > 0 )) && _bar=$(printf "█%.0s" $(seq 1 "$_filled"))
        _space=""
        (( _empty > 0 )) && _space=$(printf "░%.0s" $(seq 1 "$_empty"))

        printf "\r  ${_color}%s${reset}${dim}%s${reset} %3d%%" \
            "$_bar" "$_space" "$_progress"
        sleep "$_delay"
    done

    wait "$_pid"
    _exit_code=$?

    _bar=$(printf "█%.0s" $(seq 1 "$_width"))
    printf "\r  ${_color}%s${reset}${dim}%s${reset} %3d%%\n" \
        "$_bar" "" 100

    return "$_exit_code"
}

# ── Spinner for commands that don't expose progress ─────────────────────
show_spinner() {
    local _pid="$1"
    local _msg="${2:-Working...}"

    local _frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0

    while kill -0 "$_pid" 2>/dev/null; do
        printf "\r  %s ${green}%s${reset}" "$_msg" "${_frames[$i]}"
        i=$(( (i + 1) % ${#_frames[@]} ))
        sleep 0.08
    done

    wait "$_pid"
    local _rc=$?

    printf "\r  %s ${green}✔${reset}\n" "$_msg"
    
    return "$_rc"
}


# ══════════════════════════════════════════════════════════════════════
#  BANNER
# ══════════════════════════════════════════════════════════════════════
clear
if $USE_FIGLET; then
    echo -e "${cyan}"
    figlet -f small "   MP4 VAULT"
    echo -e "                  ${red} By Mr. Root ${reset}"
else
    echo "  ╔═══════════════════════════════════════════════╗"
    echo "  ║            V A U L T   F O R G E             ║"
    echo "  ║      Hide & Extract Files Inside Videos       ║"
    echo "  ╚═══════════════════════════════════════════════╝"
    echo -e "                  ${red}By Mr. Root${reset}"
fi
echo -e "${reset}"
echo -e "  ${dim} •Cat-Append Steganography v1.0.0  ${reset}"
gap

# Show live encryption status from config
if $ENCRYPT_PAYLOAD && $USE_OPENSSL; then
    echo -e "  ${green}  AES-256 Encryption: ENABLED 🔐${reset}"
elif $ENCRYPT_PAYLOAD && ! $USE_OPENSSL; then
    echo -e "  ${yellow}⚠   Encryption requested but openssl not found — will run unencrypted${reset}"
else
    echo -e "  ${yellow}  Encryption: DISABLED 🔓  (set ENCRYPT_PAYLOAD=true to enable)${reset}"
fi
gap

# Offer system-wide install when running inside Termux and not yet installed
_install_termux_systemwide

# ── FIRST-RUN SETUP ────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
    section "${magenta}╰┈➤【FIRST TIME SETUP】${reset}"
    echo -e "  ${dim}These defaults are saved and won't be asked again.${reset}"
    gap
    read -rp " ➤ Default scan folder (Enter to skip):" _raw
    [[ -n "$(trim "$_raw")" ]] && DEFAULT_SCAN_DIR="$(expand_path "$(trim "$_raw")")"
    read -rp " ➤ Default output folder (Enter to skip):" _raw
    [[ -n "$(trim "$_raw")" ]] && DEFAULT_OUTPUT_DIR="$(expand_path "$(trim "$_raw")")"
    _save_config
    msg ok "Defaults saved to $CONFIG_FILE"
    gap
fi

# ── MODE ───────────────────────────────────────────────────────────────
divider
echo -e "  ${white}Select mode:${reset}"
gap
echo -e "  ${blue}[1]${reset}  🔒  Hide file(s) inside a video"
echo -e "  ${blue}[2]${reset}  🔓  Extract hidden file from a video"
gap
while true; do
    read -rp "  ➤ Select an option: " _raw; mode_choice=$(trim "$_raw")
    [[ "$mode_choice" == "1" || "$mode_choice" == "2" ]] && break
    msg err "Invalid choice — enter 1 or 2."
done

# ── SCAN FOLDER ────────────────────────────────────────────────────────
section "Scan folder:"

while true; do
    gap
    echo -e "  ${blue}[1]${reset}  Default scan folder: ${dim}${DEFAULT_SCAN_DIR:-(not set)}${reset}"
    echo -e "  ${blue}[2]${reset}  Current folder:      ${dim}$(pwd)${reset}"
    echo -e "  ${blue}[3]${reset}  Custom path"
    echo -e "  ${blue}[4]${reset}  Change default scan folder"
    echo -e "  ${blue}[5]${reset}  Change default output folder"
    gap
    read -rp "  ➤ Select an option: " _raw; _fc=$(trim "$_raw")
    case "$_fc" in
        1)
            if [[ -z "$DEFAULT_SCAN_DIR" ]]; then
                msg warn2 "Default scan folder not set — let's set it now."
                read -rp "  ➤ New default scan folder: " _raw
                DEFAULT_SCAN_DIR="$(expand_path "$(trim "$_raw")")"
                _save_config
                msg ok "Default scan folder set to: $DEFAULT_SCAN_DIR"
            fi
            DIR="$DEFAULT_SCAN_DIR"; break ;;
        2) DIR="$(pwd)"; break ;;
        3) read -rp "  ➤ Folder path: " _raw
           DIR="$(expand_path "$(trim "$_raw")")"; break ;;
        4) read -rp "  ➤ New default scan folder: " _raw
           DEFAULT_SCAN_DIR="$(expand_path "$(trim "$_raw")")"
           _save_config
           msg ok "Default scan folder updated to: $DEFAULT_SCAN_DIR" ;;
        5) read -rp "  ➤ New default output folder: " _raw
           DEFAULT_OUTPUT_DIR="$(expand_path "$(trim "$_raw")")"
           _save_config
           msg ok "Default output folder updated to: $DEFAULT_OUTPUT_DIR" ;;
        *) msg err "Invalid choice — enter 1 to 5." ;;
    esac
done

[[ ! -d "$DIR" ]] && { msg err "Folder not found: $DIR"; exit 1; }
msg info "Scanning: $DIR"

# ── SCAN DEPTH ─────────────────────────────────────────────────────────
section "Scan depth:"
echo -e "  ${blue}[1]${reset}  This folder only"
echo -e "  ${blue}[2]${reset}  Include subfolders (recursive)"
gap
while true; do
    read -rp "  ➤ Select an option: " _raw; _dc=$(trim "$_raw")
    case "$_dc" in
        1) find_cmd=(find "$DIR" -maxdepth 1 -type f); break ;;
        2) find_cmd=(find "$DIR"              -type f); break ;;
        *) msg err "Invalid choice — enter 1 or 2." ;;
    esac
done

# ── CLASSIFY FILES ─────────────────────────────────────────────────────
videos=()
data_files=()

while IFS= read -r _f; do
    if is_video "$_f"; then
        videos+=("$_f")
    else
        data_files+=("$_f")
    fi
done < <("${find_cmd[@]}" 2>/dev/null | sort)

msg dbg "Found ${#videos[@]} video(s), ${#data_files[@]} non-video file(s)."

    # ── Select carrier video ──────────────────────────────────────────
    if [[ "$mode_choice" == "2" ]]; then
    section "Select carrier video:🎬"

    if (( ${#videos[@]} == 0 )); then
        msg warn2 "No videos found — enter path manually."
        read -rp "  ➤ Video path: " _raw
src="$(expand_path "$(trim "$_raw")")"

if [[ ! -e "$src" ]]; then
    msg err "File not found: $src"
    exit 1
fi

if [[ ! -f "$src" ]]; then
    msg err "Path is not a file: $src"
    exit 1
fi

is_video "$src" || { msg err "Not a valid video."; exit 1; }
    else
        list_files videos "🎬"
        while true; do
            read -rp "  ➤ Select a video: " _raw; _ic=$(trim "$_raw")
            validate_choice "$_ic" "${#videos[@]}" && break
            msg err "Invalid selection — enter a number between 1 and ${#videos[@]}."
        done
        src="${videos[$((_ic-1))]}"
    fi

    _src_sz=$(get_bytes "$src")
    msg ok "Carrier: ${src##*/}  ($(human_size "$_src_sz"))"

    # ── Output path ───────────────────────────────────────────────────
    # ── Output path ───────────────────────────────────────────────────
    section "📂 Choose Output Path"
    echo -e "  ${blue}[1]${reset}  Default output path: ${dim}${DEFAULT_OUTPUT_DIR:-(not set)}${reset}"
    echo -e "  ${blue}[2]${reset}  Current folder:      ${dim}$(pwd)${reset}"
    echo -e "  ${blue}[3]${reset}  Custom path"
    gap
    while true; do
        read -rp "  ➤ Select an option: " _raw; _opc=$(trim "$_raw")
        case "$_opc" in
            1)
                if [[ -z "$DEFAULT_OUTPUT_DIR" ]]; then
                    msg warn2 "Default output folder not set — let's set it now."
                    read -rp "  ➤ New default output folder: " _raw
                    DEFAULT_OUTPUT_DIR="$(expand_path "$(trim "$_raw")")"
                    _save_config
                    msg ok "Default output folder set to: $DEFAULT_OUTPUT_DIR"
                fi
                _od="$DEFAULT_OUTPUT_DIR"; break ;;
            2) _od="$(pwd)"; break ;;
            3) read -rp "  ➤ Output folder path: " _raw
               _od="$(expand_path "$(trim "$_raw")")"; break ;;
            *) msg err "Invalid choice — enter 1 to 3." ;;
        esac
    done
    read -rp "  ➤ Save extracted payload as (enter for random file name): " _raw; _fn=$(trim "$_raw")
    _fn="${_fn//\//}"   # B7: strip slashes so the name can't escape the chosen output folder
    if [[ -z "$_fn" ]]; then
        extract_out="${_od}/extracted_$(date +%s).bin"
    else
        extract_out="${_od}/${_fn}"
    fi

    [[ ! -d "$_od" ]] && { msg err "Output directory not found: $_od"; exit 1; }

    if [[ -f "$extract_out" ]]; then
        msg warn2 "File already exists: ${extract_out##*/}"
        read -rp "  Overwrite? (Y/n): " _raw
        [[ "${_raw,,}" == "n" ]] && { msg info "Cancelled."; exit 0; }
    fi

    # ── Was the payload encrypted? ────────────────────────────────────
    
    ENC_USED=false
    if $USE_OPENSSL; then
        gap
        read -rp "  Was this payload encrypted during hiding? (Y/n): " _raw
        [[ -z "$(trim "$_raw")" || "${_raw,,}" == "y" ]] && ENC_USED=true
    fi

    # ── Extraction key (byte-offset) ──────────────────────────────────
    
if $USE_FIGLET; then
    clear
    echo -e "${cyan}"
    figlet -f small " MP4V EXTRACTOR"
    echo -e "${magenta}🌐Github: https://github.com/nostafobic-dev/mp4vault ${reset}"
else
    clear
    echo "  ╔═══════════════════════════════════════════════╗"
    echo "  ║         E X T R A C T O R           ║"
    echo "  ║      Hide & Extract Files Inside Videos       ║"
    echo "  ╚═══════════════════════════════════════════════╝"
    echo -e "${magenta}🌐Github: https://github.com/nostafobic-dev/mp4vault${reset}"
fi
    
    section "🔑 Offset Key Needed"
    echo -e "  ${dim}${red}This is a very sensitive part ⚠${reset}"
    echo -e "  ${dim}${red}If handled recklessly, the output file could be corrupted.${reset}"
    gap;divider
    echo -e "  ${dim}Enter the offset key shown when the file was hidden.${reset}"
    echo -e "  ${dim}(It is the original byte-size of the carrier video.)${reset}"
    gap
    while true; do
        read -rp "  ➤ Enter Offset Key:" _raw; OFFSET_KEY=$(trim "$_raw")
        if [[ "$OFFSET_KEY" =~ ^[0-9]+$ ]] && (( OFFSET_KEY > 0 )); then
            break
        fi
        msg err "Invalid key — must be a positive integer."
    done

    # ── Disk space estimate ───────────────────────────────────────────
    _payload_est=$(( _src_sz - OFFSET_KEY ))
    (( _payload_est > 0 )) && { check_space "$_od" "$_payload_est" || exit 1; }

# ── Extract ───────────────────────────────────────────────────────
    
    if $ENC_USED; then
        section "🔑 Decryption Passphrase Needed"
        echo -e "  ${dim}${red} Encrypted files needs a passphrase to decrypt.🔐${reset}"
        echo -e "  ${dim}${red} Make sure the decryption key is correct.${reset}"
        echo -e "  ${dim}${red} Otherwise, file won't be decrypted even if the passphrase is correct.${reset}"
        gap; divider
        read -srp "  ➤ Decryption passphrase:" _pass; echo
        TEMP_ENC="$(mktemp "${VAULT_TMPDIR}/vault_enc_XXXXXX.bin")"
    fi
 
    gap; divider
    echo -e "  ${purple}➤ Extracting payload from the carrier video ⌛︎${reset}"
    gap
  
   
  ACTIVE_OUTPUT="$extract_out"

# ── Phase 1: Extract raw bytes (green bar) ───────────────────────
if $ENC_USED; then
    (
        tail -c +"$((OFFSET_KEY + 1))" "$src" > "$TEMP_ENC"
    ) &
    pid=$!
    show_file_progress "$pid" "$TEMP_ENC" "$_payload_est" "$green" || {
        ACTIVE_OUTPUT=""
        msg err "Extraction failed — could not read carrier file."
        exit 1
    }
else
    (
        tail -c +"$((OFFSET_KEY + 1))" "$src" > "$extract_out"
    ) &
    pid=$!
    show_file_progress "$pid" "$extract_out" "$_payload_est" "$green" || {
        ACTIVE_OUTPUT=""
        msg err "Extraction failed — could not read carrier file."
        exit 1
    }
fi

    # ── Phase 2: Decrypt (blue bar, only when ENC_USED) ─────────────
    if $ENC_USED; then
        gap
        echo -e "  ${blue}➤ Trying to decrypt the payload ⌛︎${reset}"
        gap

         (
            openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$_pass" \
                -in "$TEMP_ENC" -out "$extract_out" 2>/dev/null
        ) &
        _dec_pid=$!
        _dec_expected=$(get_bytes "$TEMP_ENC" 2>/dev/null || echo 0)
        if ! show_file_progress "$_dec_pid" "$extract_out" "$_dec_expected" "$blue"; then
            rm -f "$TEMP_ENC"; TEMP_ENC=""
            rm -f "$extract_out"
            ACTIVE_OUTPUT=""
            msg err "Decryption failed — wrong credentials or no encrypted payload found."
            exit 1
        fi

        rm -f "$TEMP_ENC"; TEMP_ENC=""
    fi
    ACTIVE_OUTPUT=""

    if [[ ! -s "$extract_out" ]]; then
        rm -f "$extract_out"
        msg err "Extraction failed — wrong key or no hidden content found."
        exit 1
    fi

    _out_sz=$(get_bytes "$extract_out")

    # ── Extraction summary ────────────────────────────────────────────
    gap
    echo -e "  ${green}╔══════════════════════════════════════════════════╗${reset}"
    echo -e "  ${green}║            </> EXTRACTION COMPLETE </>           ║${reset}"
    echo -e "  ${green}╚══════════════════════════════════════════════════╝${reset}"
    gap
    printf "  ${dim}%-22s${reset}  %s\n"  "Carrier:"       "${src##*/}"
    printf "  ${dim}%-22s${reset}  %s\n"  "Carrier size:"  "$(human_size "$_src_sz")"
    printf "  ${dim}%-22s${reset}  %s\n"  "Offset key:"    "$OFFSET_KEY"
    divider
    printf "  ${dim}%-22s${reset}  %s\n"  "Output:"        "$extract_out"
    printf "  ${dim}%-22s${reset}  %s\n"  "Payload size:"  "$(human_size "$_out_sz")"
    printf "  ${dim}%-22s${reset}  %s\n"  "Decrypted:"     "$( $ENC_USED && echo "Yes (AES-256-CBC)" || echo "No" )"
    divider
    exit 0
fi


# ══════════════════════════════════════════════════════════════════════
#  HIDE MODE
# ══════════════════════════════════════════════════════════════════════

# ── Select carrier video ───────────────────────────────────────────────

#

if $USE_FIGLET; then
    clear
    echo -e "${cyan}"
    figlet -f small "MP4V ENCRYPTOR"
    echo -e "🌐${magenta}Github: github.com/nostafobic-dev/mp4vault ${reset}"
fi

section "Carrier Video Selection 🎬"

if (( ${#videos[@]} == 0 )); then
    msg warn2 "No videos found — enter path manually."
    read -rp "  ➤ Video path: " _raw
video="$(expand_path "$(trim "$_raw")")"

if [[ ! -e "$video" ]]; then
    msg err "File not found: $video"
    exit 1
fi

if [[ ! -f "$video" ]]; then
    msg err "Path is not a file: $video"
    exit 1
fi

is_video "$video" || { msg err "Not a valid video."; exit 1; }
else
    list_files videos "🎬"
    while true; do
        read -rp "  ➤ Select a video:" _raw; _ic=$(trim "$_raw")
        validate_choice "$_ic" "${#videos[@]}" && break
        msg err "Invalid selection — enter a number between 1 and ${#videos[@]}."
    done
    video="${videos[$((_ic-1))]}"
fi

vid_sz=$(get_bytes "$video")
OFFSET_KEY="$vid_sz"
msg ok "Carrier: ${video##*/}  ($(human_size "$vid_sz"))"

# ── Select file to hide ─────────────────────────────────────────────────
section "List Of Files ⿻"

if (( ${#data_files[@]} == 0 )); then
    msg warn2 " No eligible files found — enter path manually."
    msg info "A zip file is recommended."
    read -rp "  ➤ File path: " _raw
    _mf="$(expand_path "$(trim "$_raw")")"
    [[ ! -f "$_mf" ]] && { msg err "File not found."; exit 1; }
    selected_files=("$_mf")
else
    list_files data_files "⿻"
    echo -e "  ${dim}To hide multiple files, zip them first and select the zip.${reset}"
    gap

    while true; do
        read -rp "  ➤ Select a file: " _raw; _fc=$(trim "$_raw")
        if validate_choice "$_fc" "${#data_files[@]}"; then
            selected_files=("${data_files[$((_fc-1))]}")
            break
        fi
        msg err "Invalid: '$_fc' — must be between 1 and ${#data_files[@]}."
    done
fi

gap; echo -e "  ${white}Selected file ⿻${reset}"
_fsz=$(get_bytes "${selected_files[0]}" 2>/dev/null || echo 0)
printf "  ${green}•${reset} %-44s ${dim}%s${reset}\n" " ${selected_files[0]##*/}" "        $(human_size "$_fsz")"

secret="${selected_files[0]}"

# ── Optional AES-256 encryption ───────────────────────────────────────
ENCRYPT_ACTIVE=false
if $ENCRYPT_PAYLOAD && $USE_OPENSSL; then
    section "🔒AES-256 Encryption Mode"
    echo -e "  ${dim}Enter a passphrase to encrypt the payload before hiding.${reset}"
    echo -e "  ${dim}Leave blank to skip encryption for this time.${reset}"
    gap
    read -srp "  ➤ Enter Passphrase:" _p1; echo
    read -srp "  ➤ Confirm passphrase:" _p2; echo

    if [[ -z "$_p1" ]]; then
        msg warn2 "Passphrase blank — encryption skipped for this time."
    elif [[ "$_p1" != "$_p2" ]]; then
        msg err "Passphrases do not match."; exit 1
    else
        TEMP_ENC="$(mktemp "${VAULT_TMPDIR}/vault_enc_XXXXXX.bin")"
        gap
                (
            openssl enc -aes-256-cbc -pbkdf2 -pass pass:"$_p1" \
                -in "$secret" -out "$TEMP_ENC" 2>/dev/null
        ) &
        _enc_pid=$!
     if ! show_spinner "$_enc_pid" "➤ Encrypting payload"; then
        msg err "Encryption failed."
        exit 1
     fi
        secret="$TEMP_ENC"
        ENCRYPT_ACTIVE=true
        gap
        msg ok "Payload encrypted with AES-256-CBC + PBKDF2."
    fi
fi

# ── Output path ────────────────────────────────────────────────────────
# ── Output path ────────────────────────────────────────────────────────
section "📂 Choose Output Path"
echo -e "  ${blue}[1]${reset}  Default output path: ${dim}${DEFAULT_OUTPUT_DIR:-(not set)}${reset}"
echo -e "  ${blue}[2]${reset}  Current folder:      ${dim}$(pwd)${reset}"
echo -e "  ${blue}[3]${reset}  Custom path"
gap
while true; do
    read -rp "  ➤ Select an option: " _raw; _opc=$(trim "$_raw")
    case "$_opc" in
        1)
            if [[ -z "$DEFAULT_OUTPUT_DIR" ]]; then
                msg warn2 "Default output folder not set — let's set it now."
                read -rp "  ➤ New default output folder: " _raw
                DEFAULT_OUTPUT_DIR="$(expand_path "$(trim "$_raw")")"
                _save_config
                msg ok "Default output folder set to: $DEFAULT_OUTPUT_DIR"
            fi
            _od="$DEFAULT_OUTPUT_DIR"; break ;;
        2) _od="$(pwd)"; break ;;
        3) read -rp "  ➤ Output folder path: " _raw
           _od="$(expand_path "$(trim "$_raw")")"; break ;;
        *) msg err "Invalid choice — enter 1 to 3." ;;
    esac
done
read -rp "  ➤ Name the output video (enter for random file name): " _raw; _fn=$(trim "$_raw")
_fn="${_fn//\//}"   # B7: strip slashes so the name can't escape the chosen output folder
_ext="${video##*.}"
if [[ -z "$_fn" ]]; then
    output="${_od}/Mp4Vault_$(date +%s).${_ext}"
    msg info "Auto-generated: $output"
else
    output="${_od}/${_fn}"
    [[ "$output" != *.* ]] && output="${output}.${_ext}"
fi

[[ ! -d "$_od" ]] && { msg err "Output directory not found: $_od"; exit 1; }

# Guard: cannot overwrite the carrier video itself
if [[ -f "$output" ]] && [[ "$(realpath "$output")" == "$(realpath "$video")" ]]; then
    msg err "Output path cannot overwrite the carrier video."; exit 1
fi

if [[ -f "$output" ]]; then
    msg warn2 "File already exists: ${output##*/}"
    read -rp "  Overwrite? (Y/n): " _raw
    [[ "${_raw,,}" == "n" ]] && { msg info "Cancelled."; exit 0; }
fi

# ── Disk space check ───────────────────────────────────────────────────
_secret_sz=$(get_bytes "$secret" 2>/dev/null || echo 0)
check_space "$_od" $(( vid_sz + _secret_sz )) || exit 1

# ── Perform injection ──────────────────────────────────────────────────
clear
gap; divider
if $USE_FIGLET; then
    echo -e "${cyan}"
    figlet -f small " MP4V  INJECTOR "
    echo -e "${magenta}🌐Github: https://github.com/nostafobic-dev/mp4vault${reset}"
else
    clear
    echo "  ╔═══════════════════════════════════════════════╗"
    echo "  ║        M P 4    I N J E C T O R             ║"
    echo "  ║        Hide Files Inside Videos       ║"
    echo "  ╚═══════════════════════════════════════════════╝"
    echo -e "                  ${red}By Mr. Root${reset}"
fi
gap
gap
echo -e " ${blue}Injecting the payload into carrier video ⌛︎${reset}"
gap

msg step "Carrier:    ${video##*/} ($(human_size "$vid_sz"))"
msg step "Payload:    ${selected_files[0]##*/} ($(human_size "$_secret_sz"))$( $ENCRYPT_ACTIVE && echo "  (Encryption Enabled)" || echo "" )"
gap

ACTIVE_OUTPUT="$output"
(
    cat "$video" "$secret" > "$output"
) &

pid=$!
if ! show_file_progress "$pid" "$output" "$(( vid_sz + _secret_sz ))" "$green"; then
    ACTIVE_OUTPUT=""
    msg err "Failed to write output file."
    exit 1
fi

ACTIVE_OUTPUT=""

_out_sz=$(get_bytes "$output" 2>/dev/null || echo 0)
printf "\n"
# ── Success summary ────────────────────────────────────────────────────
gap
echo -e "  ${green}╔══════════════════════════════════════════════════╗${reset}"
echo -e "  ${green}║             </> OPERATION COMPLETE </>           ║${reset}"
echo -e "  ${green}╚══════════════════════════════════════════════════╝${reset}"
gap

_hidden_label="${selected_files[0]##*/}"

printf "  ${dim}%-22s${reset}  %s\n"  "Carrier:"       "${video##*/}"
printf "  ${dim}%-22s${reset}  %s\n"  "Hidden:"        "$_hidden_label"
printf "  ${dim}%-22s${reset}  %s\n"  "Output:"        "$output"
divider
printf "  ${dim}%-22s${reset}  %s\n"  "Carrier size:"  "$(human_size "$vid_sz")"
printf "  ${dim}%-22s${reset}  %s\n"  "Payload size:"  "$(human_size "$_secret_sz")"
printf "  ${dim}%-22s${reset}  %s\n"  "Output size:"   "$(human_size "$_out_sz")"
printf "  ${dim}%-22s${reset}  %s\n"  "Encrypted:"     "$( $ENCRYPT_ACTIVE && echo "Yes (AES-256-CBC + PBKDF2)" || echo "No" )"
divider

# ── Extraction key display ─────────────────────────────────────────────
gap
echo -e "  ${yellow}╔══════════════════════════════════════════════════╗${reset}"
echo -e "  ${yellow}║      🔑  EXTRACTION KEY  —  Keep This Safe!      ║${reset}"
echo -e "  ${yellow}╚══════════════════════════════════════════════════╝${reset}"
gap
printf "  %-24s  ${green}%s${reset}\n"  "Offset key:"  "$OFFSET_KEY"
$ENCRYPT_ACTIVE && printf "  %-24s  ${green}%s${reset}\n" "Passphrase:" "$_p1"
gap
echo -e "  ${dim}${red}The offset key is the original byte-size of the carrier video.${reset}"
echo -e "  ${dim}${red}Without it, the extracted data will be corrupted or missing.${reset}"
gap
echo -e "  ${dim}To regenerate: stat -c%s \"${video##*/}\"  (Linux)${reset}"
divider
