# Shared helpers for nvim-pane and nvim-window. Sourced, not run.
# Works with the bash 3.2 that ships with macOS (no associative arrays, no ${x,,}).

NT_PROG=$(basename "$0")
NT_SHELLS=" zsh -zsh bash -bash sh -sh fish dash ksh tcsh csh login "

# Exit codes shared by both scripts
NT_OK=0 NT_USAGE=1 NT_NO_TMUX=2 NT_BUSY=3 NT_NEED_TARGET=4 NT_NOT_FOUND=5

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

# Server socket of the nvim running under a pane's shell. nvim 0.10+ runs a UI
# process with the server as its child, and the socket is named after the server,
# so every descendant pid is checked.
nt_nvim_socket() {
  local root=$1 pids pid dir sock
  pids=$(ps -A -o pid= -o ppid= | awk -v root="$root" '
    { kids[$2] = kids[$2] " " $1 }
    END { q = root; while (q != "") { split(q, a, " "); q = "";
            for (i in a) { if (a[i] == "") continue; print a[i]; q = q " " kids[a[i]] } } }')
  for dir in "${XDG_RUNTIME_DIR:-}" "${TMPDIR%/}/nvim.${USER}"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    for pid in $pids; do
      sock=$(find "$dir" -type s -name "nvim.${pid}.*" -print 2>/dev/null | head -n 1)
      [ -n "$sock" ] && { printf '%s' "$sock"; return 0; }
    done
  done
  return 1
}

# Vim's fnameescape for the :edit fallback
nt_vim_escape() { printf '%s' "$1" | sed -e 's/[ %#|"\\]/\\&/g'; }

# --- actions (each honours NT_DRY=1) ---

nt_open_in_shell() {   # target file
  local cmd="nvim"; [ -n "$2" ] && cmd="nvim $(nt_q "$2")"
  [ "${NT_DRY:-0}" = 1 ] && { echo "dry-run: type '$cmd' into $1"; return; }
  tmux send-keys -t "$1" -l "$cmd" && tmux send-keys -t "$1" Enter
}

nt_open_in_nvim() {    # target pane_pid file
  [ -z "$3" ] && { [ "${NT_DRY:-0}" = 1 ] && echo "dry-run: nvim already open in $1, nothing to open"; return 0; }
  local sock; sock=$(nt_nvim_socket "$2")
  if [ -n "$sock" ]; then
    [ "${NT_DRY:-0}" = 1 ] && { echo "dry-run: nvim --server $sock --remote $3"; return; }
    nvim --server "$sock" --remote "$3"
  else
    [ "${NT_DRY:-0}" = 1 ] && { echo "dry-run: no nvim socket found; send Escape :e $3 to $1"; return; }
    tmux send-keys -t "$1" Escape && tmux send-keys -t "$1" -l ":e $(nt_vim_escape "$3")" && tmux send-keys -t "$1" Enter
  fi
}

# New and replaced panes start a plain login shell, and nvim is then typed into it.
# Running "zsh -c 'nvim f; exec zsh'" instead would keep zsh as the pane's foreground
# process, so tmux would report the pane as a shell while nvim is open, and the next
# call would type "nvim f" into nvim as text.
NT_LOGIN_SHELL="${SHELL:-/bin/zsh} -l"

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
