#!/usr/bin/env bash
# tyte - minimal terminal text editor for Termux/Bash
# Usage: tyte <filename>
echo("Made by Tytedev")

tyte() {
  local file="$1"

  if [[ -z "$file" ]]; then
    echo -e "\033[91m[Error] Please provide a filename. Usage: tyte <filename>\033[0m"
    return 1
  fi

  # --- Colors & Theme ---
  local bg="\033[48;2;25;50;80m"       # dark navy background (fixed as requested, was #376A91)
  local fg="\033[38;2;235;235;235m"    # off-white text
  local line_bg="\033[48;2;15;30;48m"  # darker navy for the gutter
  local line_fg="\033[38;2;120;170;210m"
  local reset="\033[0m"
  local color_js="\033[38;2;255;215;0m\033[1m"
  local color_html="\033[38;2;87;203;255m\033[1m"

  # --- Safe temp storage ---
  local tmp_dir="$HOME/.tyte_tmp"
  mkdir -p "$tmp_dir" || { echo "[Error] Cannot create $tmp_dir"; return 1; }
  local temp_buffer
  temp_buffer="$(mktemp "$tmp_dir/buffer_XXXXXX.tmp")" || return 1

  # Always clean up and restore terminal, even on Ctrl-C or unexpected exit
  local restored=0
  _tyte_cleanup() {
    [[ "$restored" -eq 1 ]] && return
    restored=1
    stty ixon 2>/dev/null
    stty sane 2>/dev/null
    printf '\033[?1049l'
    rm -f "$temp_buffer"
  }
  trap _tyte_cleanup EXIT INT TERM

  # Enter alternate screen buffer *after* trap is armed
  printf '\033[?1049h'
  stty -ixon 2>/dev/null
  printf '%b' "${bg}${fg}"
  clear

  _draw_header() {
    printf '%b\n' "${bg}${fg}======================================================================${reset}"
    printf '%b\n' "${bg}${fg}   TYTE EDITOR | File: $file${reset}"
    printf '%b\n' "${bg}${fg}   Commands: [ :s ] Save   [ :e ] Exit${reset}"
    printf '%b\n' "${bg}${fg}======================================================================${reset}"
  }

  _highlight() {
    local s="$1"
    s=$(printf '%s' "$s" | sed -E "s/(<\/?[a-zA-Z][^>]*>)/$(printf '%b' "$color_html")\1$(printf '%b' "${reset}${bg}${fg}")/g")
    s=$(printf '%s' "$s" | sed -E "s/\b(const|let|var|function|if|else|return|console|import|export)\b/$(printf '%b' "$color_js")\1$(printf '%b' "${reset}${bg}${fg}")/g")
    printf '%s' "$s"
  }

  _draw_header

  local line_num=1

  # Load existing file (fixed: file wasn't being displayed with correct numbering flow before input loop)
  if [[ -f "$file" ]]; then
    while IFS= read -r existing_line || [[ -n "$existing_line" ]]; do
      printf '%s\n' "$existing_line" >> "$temp_buffer"
      printf '%b %s %b %s\n' "${line_bg}${line_fg}" "$(printf '%03d' "$line_num")" "${reset}${bg}${fg}" "$(_highlight "$existing_line")"
      ((line_num++))
    done < "$file"
  fi

  while true; do
    printf '%b %s %b ' "${line_bg}${line_fg}" "$(printf '%03d' "$line_num")" "${reset}${bg}${fg}"

    if ! IFS= read -r -e raw_line; then
      break   # EOF (Ctrl-D) exits cleanly instead of looping forever
    fi

    case "$raw_line" in
      ":s")
        cat "$temp_buffer" > "$file"
        printf '\033[1A\033[K%b *** %b[System] Saved '\''%s'\''%b\n' "${line_bg}${fg}" "\033[32m" "$file" "$reset"
        sleep 1
        printf '\033[1A\033[K'
        continue
        ;;
      ":e")
        break
        ;;
    esac

    printf '\033[1A\033[K'
    printf '%b %s %b %s\n' "${line_bg}${line_fg}" "$(printf '%03d' "$line_num")" "${reset}${bg}${fg}" "$(_highlight "$raw_line")"

    printf '%s\n' "$raw_line" >> "$temp_buffer"
    ((line_num++))
  done

  # trap handles cleanup/restore automatically
}
