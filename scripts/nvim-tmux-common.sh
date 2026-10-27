# Shared helpers for nvim-pane and nvim-window. Sourced, not run.
# Works with the bash 3.2 that ships with macOS (no associative arrays, no ${x,,}).

NT_PROG=$(basename "$0")
NT_SHELLS=" zsh -zsh bash -bash sh -sh fish dash ksh tcsh csh login "

# Exit codes shared by both scripts
NT_OK=0 NT_USAGE=1 NT_NO_TMUX=2 NT_BUSY=3 NT_NEED_TARGET=4 NT_NOT_FOUND=5

# Tab separates tmux format fields, because session names, window names and
# process names can contain spaces
NT_TAB=$(printf '\t')

nt_err() { printf '%s: %s\n' "$NT_PROG" "$1" >&2; }

nt_require_tmux() {
  command -v tmux >/dev/null 2>&1 || { nt_err "tmux is not installed"; exit $NT_NO_TMUX; }
  [ -n "${TMUX:-}" ] || { nt_err "not inside a tmux session (TMUX is not set)"; exit $NT_NO_TMUX; }
  tmux display-message -p '' >/dev/null 2>&1 || { nt_err "cannot reach the tmux server"; exit $NT_NO_TMUX; }
}

nt_interactive() { [ -t 0 ] && [ -t 1 ]; }

# shell | nvim | other, from #{pane_current_command}
nt_kind() {
  case "$NT_SHELLS" in *" $1 "*) echo shell; return ;; esac
  case "$1" in nvim) echo nvim ;; *) echo other ;; esac
}

# Absolute path for FILE, resolved against the caller's directory, because the
# target pane usually has a different working directory. The file may not exist yet.
nt_abs() {
  case "$1" in
    "") return ;;
    /*) printf '%s' "$1" ;;
    *) local d; d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || d="$PWD/$(dirname "$1")"
       printf '%s/%s' "$d" "$(basename "$1")" ;;
  esac
}

nt_q() { printf '%q' "$1"; }

# Refuse file names with control characters: a newline would be sent as Enter
nt_check_name() {
  case "$1" in *[[:cntrl:]]*) nt_err "file name contains a control character; refusing to type it"; exit $NT_USAGE ;; esac
}

# Server socket of the nvim running under a pane's shell. nvim 0.10+ runs a UI
# process with the server as its child, and the socket is named after the server,
# so every descendant pid is checked.
nt_nvim_socket() {
  local root=$1 pids pid dir sock
  pids=$(ps -A -o pid= -o ppid= | awk -v root="$root" '
    { kids[$2] = kids[$2] " " $1 }
    END { q = root; while (q != "") { split(q, a, " "); q = "";
            for (i in a) { if (a[i] == "") continue; print a[i]; q = q " " kids[a[i]] } } }')
  local tmp=${TMPDIR:-/tmp}; tmp=${tmp%/}
  for dir in "${XDG_RUNTIME_DIR:-}" "$tmp/nvim.${USER:-$(id -un)}"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    for pid in $pids; do
      sock=$(find "$dir" -type s -name "nvim.${pid}.*" -print 2>/dev/null | head -n 1)
      [ -n "$sock" ] && { printf '%s' "$sock"; return 0; }
    done
  done
  return 1
}

# The path as a Vim single-quoted string (only ' needs doubling), so the :edit
# fallback can pass it through fnameescape() instead of typing it raw
nt_vim_string() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

# --- actions (each honours NT_DRY=1) ---

nt_open_in_shell() {   # target file
  local cmd="nvim"; [ -n "$2" ] && cmd="nvim $(nt_q "$2")"
  [ "${NT_DRY:-0}" = 1 ] && { echo "dry-run: type '$cmd' into $1"; return; }
  # A pane in copy mode or view mode would read the keys as copy-mode commands
  [ "$(tmux display-message -p -t "$1" '#{pane_in_mode}')" = 1 ] && tmux send-keys -t "$1" -X cancel
  tmux send-keys -t "$1" -l "$cmd" && tmux send-keys -t "$1" Enter
}

nt_open_in_nvim() {    # target pane_pid file
  [ -z "$3" ] && { [ "${NT_DRY:-0}" = 1 ] && echo "dry-run: nvim already open in $1, nothing to open"; return 0; }
  local sock ex; sock=$(nt_nvim_socket "$2")
  ex=":execute 'edit' fnameescape($(nt_vim_string "$3"))"
  if [ "${NT_DRY:-0}" = 1 ]; then
    if [ -n "$sock" ]; then echo "dry-run: nvim --server $sock --remote $3"; else echo "dry-run: no nvim socket found; type Escape $ex into $1"; fi
    return
  fi
  # A stale socket makes --remote fail; fall back to typing the :execute command
  [ -n "$sock" ] && nvim --server "$sock" --remote "$3" 2>/dev/null && return 0
  [ "$(tmux display-message -p -t "$1" '#{pane_in_mode}')" = 1 ] && tmux send-keys -t "$1" -X cancel
  tmux send-keys -t "$1" Escape && tmux send-keys -t "$1" -l "$ex" && tmux send-keys -t "$1" Enter
}

# New and replaced panes start a shell, and nvim is then typed into it.
# Running "zsh -c 'nvim f; exec zsh'" instead would keep zsh as the pane's foreground
# process, so tmux would report the pane as a shell while nvim is open, and the next
# call would type "nvim f" into nvim as text.
# Use tmux's own default-command when set (here it wraps zsh in
# reattach-to-user-namespace for the macOS clipboard), otherwise a login shell.
NT_LOGIN_SHELL=$(tmux show-options -gv default-command 2>/dev/null)
[ -n "$NT_LOGIN_SHELL" ] || NT_LOGIN_SHELL="${SHELL:-/bin/zsh} -l"

nt_respawn() {         # target file
  local cwd; cwd=$(tmux display-message -p -t "$1" '#{pane_current_path}')
  [ "${NT_DRY:-0}" = 1 ] && { echo "dry-run: stop the program in $1, start a shell there, then:"; nt_open_in_shell "$1" "$2"; return; }
  tmux respawn-pane -k -t "$1" -c "$cwd" "$NT_LOGIN_SHELL" && nt_open_in_shell "$1" "$2"
}

nt_split() {           # window-target file h|v  -> prints new pane target
  [ "${NT_DRY:-0}" = 1 ] && { echo "dry-run: split $1 (-$3), start a shell, then type nvim" >&2; echo "$1.new"; return; }
  local t; t=$(tmux split-window "-$3" -t "$1" -c "$PWD" -P -F '#{pane_id}' "$NT_LOGIN_SHELL") || return 1
  nt_open_in_shell "$t" "$2" || return 1
  tmux display-message -p -t "$t" '#{session_name}:#{window_index}.#{pane_index}'
}

nt_new_window() {      # session file -> prints new window target
  [ "${NT_DRY:-0}" = 1 ] && { echo "dry-run: new window in $1, start a shell, then type nvim" >&2; echo "$1:new"; return; }
  local t; t=$(tmux new-window -t "$1:" -c "$PWD" -P -F '#{pane_id}' "$NT_LOGIN_SHELL") || return 1
  nt_open_in_shell "$t" "$2" || return 1
  tmux display-message -p -t "$t" '#{session_name}:#{window_index}'
}

nt_focus() {           # pane-or-window target
  [ "${NT_DRY:-0}" = 1 ] || [ "${NT_FOCUS:-1}" = 0 ] && return 0
  tmux select-window -t "$1" 2>/dev/null; tmux select-pane -t "$1" 2>/dev/null; return 0
}
