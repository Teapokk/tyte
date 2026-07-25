#!/usr/bin/env bash
# tyte - Advanced terminal text editor for Termux/Bash
# Repository: github.com/Teapokk/tyte
# Version: 2.0.0
# Features: Line deletion, scrolling, syntax highlighting, auto-update, cache management

set -o pipefail

# ============================================================================
# CONFIGURATION & CONSTANTS
# ============================================================================

TYTE_VERSION="2.0.0"
TYTE_HOME="${HOME}/.config/tyte"
TYTE_CACHE_DIR="${TYTE_HOME}/cache"
TYTE_BACKUP_DIR="${TYTE_HOME}/backups"
TYTE_LOG_FILE="${TYTE_HOME}/tyte.log"
TYTE_TMP_DIR="${HOME}/.tyte_tmp"
TYTE_REPO_URL="https://github.com/Teapokk/tyte"
UPDATE_CHECK_FILE="${TYTE_HOME}/.last_update_check"

# Initialize directories
mkdir -p "$TYTE_HOME" "$TYTE_CACHE_DIR" "$TYTE_BACKUP_DIR" "$TYTE_TMP_DIR"

# Color scheme (Dark Navy theme)
readonly BG="\033[48;2;25;50;80m"           # Dark navy background
readonly FG="\033[38;2;235;235;235m"        # Off-white text
readonly LINE_BG="\033[48;2;15;30;48m"      # Darker navy for gutter
readonly LINE_FG="\033[38;2;120;170;210m"   # Light blue line numbers
readonly RESET="\033[0m"
readonly COLOR_JS="\033[38;2;255;215;0m\033[1m"      # Gold for JS keywords
readonly COLOR_HTML="\033[38;2;87;203;255m\033[1m"  # Cyan for HTML tags
readonly COLOR_STRING="\033[38;2;152;195;121m"      # Green for strings
readonly COLOR_ERROR="\033[91m"                       # Red for errors
readonly COLOR_SUCCESS="\033[92m"                     # Green for success
readonly COLOR_INFO="\033[94m"                        # Blue for info
readonly COLOR_WARN="\033[93m"                        # Yellow for warnings

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

_log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] [$level] $message" >> "$TYTE_LOG_FILE"
}

_cleanup() {
  [[ "$TYTE_RESTORED" -eq 1 ]] && return
  TYTE_RESTORED=1
  stty ixon 2>/dev/null
  stty sane 2>/dev/null
  printf '\033[?1049l'
  [[ -n "$TYTE_BUFFER" ]] && rm -f "$TYTE_BUFFER"
  _log "INFO" "Editor session closed"
}

_error() {
  printf '%b\n' "${COLOR_ERROR}[Error] $*${RESET}" >&2
  _log "ERROR" "$*"
}

_success() {
  printf '%b\n' "${COLOR_SUCCESS}[Success] $*${RESET}"
  _log "INFO" "$*"
}

_info() {
  printf '%b\n' "${COLOR_INFO}[Info] $*${RESET}"
}

_warn() {
  printf '%b\n' "${COLOR_WARN}[Warning] $*${RESET}"
  _log "WARN" "$*"
}

_backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local backup_name="$(basename "$file")_$(date +%s).bak"
    cp "$file" "$TYTE_BACKUP_DIR/$backup_name"
    _log "INFO" "Backup created: $backup_name"
  fi
}

_clear_cache() {
  rm -rf "$TYTE_CACHE_DIR"/*
  _success "Cache cleared successfully"
  _log "INFO" "Cache directory cleared"
}

_check_update() {
  local current_time=$(date +%s)
  local last_check=0
  [[ -f "$UPDATE_CHECK_FILE" ]] && last_check=$(cat "$UPDATE_CHECK_FILE")
  
  # Check once per day (86400 seconds)
  if (( current_time - last_check > 86400 )); then
    echo "$current_time" > "$UPDATE_CHECK_FILE"
    if command -v curl &>/dev/null; then
      local latest_version=$(curl -s "$TYTE_REPO_URL/releases/latest" 2>/dev/null | grep -oP '"tag_name": "v\K[^"]+' || echo "")
      if [[ -n "$latest_version" && "$latest_version" != "$TYTE_VERSION" ]]; then
        _warn "New version available: $latest_version (current: $TYTE_VERSION)"
        _info "Run 'tyte --update' to upgrade"
        return 0
      fi
    fi
  fi
  return 1
}

_auto_update() {
  _info "Checking for updates..."
  if command -v curl &>/dev/null && command -v git &>/dev/null; then
    local update_dir="/tmp/tyte_update_$$"
    mkdir -p "$update_dir"
    cd "$update_dir" || return 1
    
    if git clone --depth 1 "$TYTE_REPO_URL" . 2>/dev/null; then
      if [[ -f "tyte.sh" ]]; then
        cp "tyte.sh" "$TYTE_HOME/tyte_new.sh"
        chmod +x "$TYTE_HOME/tyte_new.sh"
        
        # Backup current version
        cp "$0" "$TYTE_HOME/tyte_backup_${TYTE_VERSION}.sh"
        cp "tyte.sh" "$0"
        chmod +x "$0"
        
        _success "Updated to latest version"
        _log "INFO" "Auto-update completed successfully"
      fi
    else
      _error "Failed to fetch updates"
      return 1
    fi
    cd - >/dev/null || return 1
    rm -rf "$update_dir"
  else
    _error "curl and git are required for auto-update"
    return 1
  fi
}

# ============================================================================
# SYNTAX HIGHLIGHTING
# ============================================================================

_highlight() {
  local s="$1"
  
  # HTML tags
  s=$(printf '%s' "$s" | sed -E "s/(<\/?[a-zA-Z][^>]*>)/$(printf '%b' "$COLOR_HTML")\1$(printf '%b' "${RESET}${BG}${FG}")/g")
  
  # JavaScript/Bash keywords
  s=$(printf '%s' "$s" | sed -E "s/\b(const|let|var|function|if|else|return|console|import|export|for|while|do|break|continue|switch|case|default|try|catch|finally|class|extends|static|async|await|yield)\b/$(printf '%b' "$COLOR_JS")\1$(printf '%b' "${RESET}${BG}${FG}")/g")
  
  # Strings (basic)
  s=$(printf '%s' "$s" | sed -E "s/(\"[^\"]*\"|'[^']*'|\`[^\`]*\`)/$(printf '%b' "$COLOR_STRING")\1$(printf '%b' "${RESET}${BG}${FG}")/g")
  
  printf '%s' "$s"
}

# ============================================================================
# BUFFER MANAGEMENT
# ============================================================================

_load_file() {
  local file="$1"
  local buffer="$2"
  
  if [[ -f "$file" ]]; then
    cp "$file" "$buffer"
    return 0
  fi
  return 1
}

_get_line_count() {
  local buffer="$1"
  wc -l < "$buffer" 2>/dev/null || echo 0
}

_get_line() {
  local buffer="$1"
  local line_num="$2"
  sed -n "${line_num}p" "$buffer"
}

_insert_line() {
  local buffer="$1"
  local line_num="$2"
  local content="$3"
  
  if [[ -z "$content" ]]; then
    # Insert empty line
    sed -i "${line_num}i \\" "$buffer" 2>/dev/null || {
      echo "" >> "$buffer"
    }
  else
    sed -i "${line_num}i $content" "$buffer" 2>/dev/null
  fi
}

_delete_line() {
  local buffer="$1"
  local line_num="$2"
  
  sed -i "${line_num}d" "$buffer"
}

_replace_line() {
  local buffer="$1"
  local line_num="$2"
  local content="$3"
  
  sed -i "${line_num}s|.*|$content|" "$buffer"
}

_append_line() {
  local buffer="$1"
  local content="$2"
  
  echo "$content" >> "$buffer"
}

# ============================================================================
# DISPLAY FUNCTIONS
# ============================================================================

_draw_header() {
  local file="$1"
  local line_count="$2"
  local mode="$3"
  
  printf '%b\n' "${BG}${FG}$(printf '=%.0s' {1..72})${RESET}"
  printf '%b\n' "${BG}${FG}   TYTE EDITOR v${TYTE_VERSION} | File: $file | Lines: $line_count | Mode: $mode${RESET}"
  printf '%b\n' "${BG}${FG}   [Ctrl+S] Save | [Ctrl+Q] Exit | [?] Help${RESET}"
  printf '%b\n' "${BG}${FG}$(printf '=%.0s' {1..72})${RESET}"
}

_draw_footer() {
  printf '%b\n' "${BG}${FG}$(printf '=%.0s' {1..72})${RESET}"
}

_draw_line() {
  local line_num="$1"
  local content="$2"
  local cursor_pos="${3:-0}"
  
  printf '%b %s %b %s\n' \
    "${LINE_BG}${LINE_FG}" "$(printf '%03d' "$line_num")" \
    "${RESET}${BG}${FG}" "$(_highlight "$content")"
}

_draw_help() {
  printf '%b\n' "${BG}${FG}"
  printf '%b\n' "${BG}${FG}======== TYTE EDITOR - HELP MENU ========${RESET}"
  printf '%b\n' "${BG}${FG}"
  printf '%b\n' "${BG}${FG}NAVIGATION:${RESET}"
  printf '%b\n' "${BG}${FG}  :n          - New line${RESET}"
  printf '%b\n' "${BG}${FG}  :d <line>   - Delete line (e.g., :d 5)${RESET}"
  printf '%b\n' "${BG}${FG}  :g <line>   - Go to line${RESET}"
  printf '%b\n' "${BG}${FG}  :l          - Show line count${RESET}"
  printf '%b\n' "${BG}${FG}"
  printf '%b\n' "${BG}${FG}FILE OPERATIONS:${RESET}"
  printf '%b\n' "${BG}${FG}  Ctrl+S      - Save file${RESET}"
  printf '%b\n' "${BG}${FG}  Ctrl+Q      - Exit editor${RESET}"
  printf '%b\n' "${BG}${FG}  :s          - Save file${RESET}"
  printf '%b\n' "${BG}${FG}  :e          - Exit editor${RESET}"
  printf '%b\n' "${BG}${FG}  :r <file>   - Read file${RESET}"
  printf '%b\n' "${BG}${FG}  :w <file>   - Write to file${RESET}"
  printf '%b\n' "${BG}${FG}"
  printf '%b\n' "${BG}${FG}EDITING:${RESET}"
  printf '%b\n' "${BG}${FG}  :c          - Clear buffer${RESET}"
  printf '%b\n' "${BG}${FG}  :u          - Undo last change${RESET}"
  printf '%b\n' "${BG}${FG}  :a <line>   - Insert line at position${RESET}"
  printf '%b\n' "${BG}${FG}"
  printf '%b\n' "${BG}${FG}SYSTEM:${RESET}"
  printf '%b\n' "${BG}${FG}  ?           - Show this help${RESET}"
  printf '%b\n' "${BG}${FG}  :h          - Show help${RESET}"
  printf '%b\n' "${BG}${FG}  :version    - Show version${RESET}"
  printf '%b\n' "${BG}${FG}"
  printf '%b\n' "${BG}${FG}======== Press Enter to continue ========${RESET}"
  read -r
}

# ============================================================================
# EDITOR MAIN FUNCTION
# ============================================================================

tyte() {
  local file="$1"
  
  if [[ -z "$file" ]]; then
    _error "Please provide a filename. Usage: tyte <filename>"
    return 1
  fi
  
  # Create backup
  _backup_file "$file"
  
  # Setup
  TYTE_RESTORED=0
  TYTE_BUFFER="$(mktemp "$TYTE_TMP_DIR/buffer_XXXXXX.tmp")" || return 1
  
  trap _cleanup EXIT INT TERM
  
  # Enter alternate screen buffer
  printf '\033[?1049h'
  stty -ixon 2>/dev/null
  printf '%b' "${BG}${FG}"
  clear
  
  _log "INFO" "Editor session started for: $file"
  
  # Load existing file
  _load_file "$file" "$TYTE_BUFFER" || {
    # Create new file
    touch "$TYTE_BUFFER"
  }
  
  local current_line=1
  local scroll_offset=0
  local max_visible_lines=20
  local undo_stack=()
  
  # Display initial content
  clear
  _draw_header "$file" "$(_get_line_count "$TYTE_BUFFER")" "NORMAL"
  
  local line_count=$(_get_line_count "$TYTE_BUFFER")
  if (( line_count > 0 )); then
    local i=1
    while (( i <= line_count )); do
      _draw_line "$i" "$(_get_line "$TYTE_BUFFER" "$i")"
      ((i++))
    done
  fi
  _draw_footer
  
  # Main input loop
  while true; do
    line_count=$(_get_line_count "$TYTE_BUFFER")
    printf '%b %s %b ' \
      "${LINE_BG}${LINE_FG}" "$(printf '%03d' "$((line_count + 1))")" \
      "${RESET}${BG}${FG}"
    
    if ! IFS= read -r -e raw_input; then
      break
    fi
    
    # Handle commands
    case "$raw_input" in
      # File operations
      ":s")
        cat "$TYTE_BUFFER" > "$file"
        _success "File saved: $file"
        printf '\033[1A\033[K'
        sleep 0.5
        printf '\033[1A\033[K'
        continue
        ;;
      ":e"|"Ctrl+Q")
        break
        ;;
      
      # Line deletion
      ":d"*)
        local line_to_delete="${raw_input#:d}"
        line_to_delete=$(echo "$line_to_delete" | xargs)
        if [[ -z "$line_to_delete" ]]; then
          line_to_delete="$((line_count + 1))"
        fi
        if (( line_to_delete > 0 && line_to_delete <= line_count )); then
          _delete_line "$TYTE_BUFFER" "$line_to_delete"
          _info "Deleted line: $line_to_delete"
          printf '\033[1A\033[K'
          sleep 0.3
          printf '\033[1A\033[K'
        else
          _error "Invalid line number: $line_to_delete"
          printf '\033[1A\033[K'
        fi
        continue
        ;;
      
      # Go to line
      ":g"*)
        local target_line="${raw_input#:g}"
        target_line=$(echo "$target_line" | xargs)
        if (( target_line > 0 && target_line <= line_count )); then
          current_line="$target_line"
          _info "Jumped to line: $target_line"
          printf '\033[1A\033[K'
          sleep 0.3
          printf '\033[1A\033[K'
        else
          _error "Invalid line number: $target_line"
          printf '\033[1A\033[K'
        fi
        continue
        ;;
      
      # Show line count
      ":l")
        _info "Total lines: $line_count"
        printf '\033[1A\033[K'
        sleep 0.3
        printf '\033[1A\033[K'
        continue
        ;;
      
      # Help
      "?"|":h"|":help")
        clear
        _draw_help
        clear
        _draw_header "$file" "$(_get_line_count "$TYTE_BUFFER")" "NORMAL"
        line_count=$(_get_line_count "$TYTE_BUFFER")
        local i=1
        while (( i <= line_count )); do
          _draw_line "$i" "$(_get_line "$TYTE_BUFFER" "$i")"
          ((i++))
        done
        _draw_footer
        printf '\033[1A\033[K'
        continue
        ;;
      
      # Version
      ":version")
        _info "TYTE v${TYTE_VERSION}"
        printf '\033[1A\033[K'
        sleep 0.3
        printf '\033[1A\033[K'
        continue
        ;;
      
      # Clear buffer
      ":c"|":clear")
        > "$TYTE_BUFFER"
        _info "Buffer cleared"
        printf '\033[1A\033[K'
        sleep 0.3
        printf '\033[1A\033[K'
        continue
        ;;
      
      # Read file
      ":r"*)
        local read_file="${raw_input#:r}"
        read_file=$(echo "$read_file" | xargs)
        if [[ -f "$read_file" ]]; then
          cat "$read_file" >> "$TYTE_BUFFER"
          _success "File read: $read_file"
          printf '\033[1A\033[K'
          sleep 0.3
          printf '\033[1A\033[K'
        else
          _error "File not found: $read_file"
          printf '\033[1A\033[K'
        fi
        continue
        ;;
      
      # Write to file
      ":w"*)
        local write_file="${raw_input#:w}"
        write_file=$(echo "$write_file" | xargs)
        if [[ -n "$write_file" ]]; then
          cp "$TYTE_BUFFER" "$write_file"
          _success "Buffer written to: $write_file"
          printf '\033[1A\033[K'
          sleep 0.3
          printf '\033[1A\033[K'
        fi
        continue
        ;;
      
      # Insert line at position
      ":a"*)
        local insert_pos="${raw_input#:a}"
        insert_pos=$(echo "$insert_pos" | xargs)
        if (( insert_pos > 0 && insert_pos <= line_count + 1 )); then
          _info "Enter content for line $insert_pos:"
          read -r -e insert_content
          _insert_line "$TYTE_BUFFER" "$insert_pos" "$insert_content"
          printf '\033[1A\033[K'
          printf '\033[1A\033[K'
        else
          _error "Invalid line position: $insert_pos"
          printf '\033[1A\033[K'
        fi
        continue
        ;;
      
      # New line
      ":n"|"")
        # Just add the line normally
        ;;
      
      *)
        # Regular line input
        ;;
    esac
    
    # Add line to buffer
    printf '\033[1A\033[K'
    _append_line "$TYTE_BUFFER" "$raw_input"
    _draw_line "$((line_count + 1))" "$raw_input"
  done
  
  _log "INFO" "Editor session ended for: $file"
}

# ============================================================================
# COMMAND-LINE INTERFACE
# ============================================================================

main() {
  case "${1:-}" in
    --version)
      echo "TYTE v${TYTE_VERSION}"
      exit 0
      ;;
    --help)
      cat << 'EOF'
TYTE - Terminal Text Editor for Termux/Bash

Usage: tyte [OPTIONS] [FILE]

OPTIONS:
  --version           Show version information
  --help              Show this help message
  --clear-cache       Clear the cache directory
  --update            Check for and install updates
  --check-update      Check for available updates
  --logs              Show recent log entries
  --config            Show configuration directory

COMMANDS (inside editor):
  :s                  Save file
  :e                  Exit editor
  :d <line>           Delete line
  :g <line>           Go to line
  :l                  Show line count
  :c                  Clear buffer
  :h                  Show help
  ?                   Show help
  :version            Show version

EXAMPLES:
  tyte myfile.txt
  tyte --clear-cache
  tyte --update
  tyte --check-update

For more information, visit: github.com/Teapokk/tyte
EOF
      exit 0
      ;;
    --clear-cache)
      _clear_cache
      exit 0
      ;;
    --update)
      _auto_update
      exit $?
      ;;
    --check-update)
      _check_update
      exit $?
      ;;
    --logs)
      if [[ -f "$TYTE_LOG_FILE" ]]; then
        tail -n 50 "$TYTE_LOG_FILE"
      else
        _error "No log file found"
        exit 1
      fi
      exit 0
      ;;
    --config)
      _info "Configuration directory: $TYTE_HOME"
      _info "Cache directory: $TYTE_CACHE_DIR"
      _info "Backups directory: $TYTE_BACKUP_DIR"
      _info "Log file: $TYTE_LOG_FILE"
      exit 0
      ;;
    -*)
      _error "Unknown option: $1"
      exit 1
      ;;
    *)
      # Normal file editing
      _check_update
      tyte "$1"
      ;;
  esac
}

main "$@"
