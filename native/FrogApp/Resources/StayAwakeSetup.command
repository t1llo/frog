#!/usr/bin/env bash
#
# Frog's stay-awake guide: walks you through allowing two power commands in
# Terminal, one stage per screen, or through removing that access again.

set -euo pipefail

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""
fi

_STAGE_INDEX=0

# Clears the terminal so only the current stage shows; piped output stays as it is.
_clear() {
  [[ -t 1 ]] || return 0
  if command -v tput >/dev/null 2>&1; then tput clear; else printf '\033[2J\033[3J\033[H'; fi
}

stage() {
  _clear
  _STAGE_INDEX=$((_STAGE_INDEX + 1))
  printf '\n%s%s▸ Stage %s/%s · %s%s\n' "$BOLD" "$BLUE" "$_STAGE_INDEX" "$TOTAL_STAGES" "$1" "$RESET"
}

say()  { printf '  %s\n' "$1"; }
step() { printf '  %s•%s %s\n' "$BLUE" "$RESET" "$1"; }

pause() {
  printf '  %s%s%s ' "$DIM" "${1:-Press Enter to continue}" "$RESET"
  read -r _ || true
}

# A y/N question; succeeds on yes.
confirm() {
  local reply=""
  printf '  %s? %s [y/N] ' "$YELLOW" "$1"
  read -r reply || true
  [[ "$reply" =~ ^[Yy] ]]
}

# Clears, then shows a closing headline.
closing() {
  _clear
  printf '\n%s%s  ✓ %s%s\n\n' "$BOLD" "$GREEN" "$1" "$RESET"
}

TOTAL_STAGES=3

MODE=${1:-setup}
RESULT_FILE=${2:-}
OUTCOME=failed
umask 077
if [[ -n "$RESULT_FILE" ]]; then
    # Frog watches this process, so a guide that is killed does not keep it waiting.
    { printf '%s\n' "$$" > "$RESULT_FILE.pid.tmp" && /bin/mv "$RESULT_FILE.pid.tmp" "$RESULT_FILE.pid"; } 2>/dev/null || true
fi
complete_guide() {
    local code=$?
    trap - EXIT
    if [[ -n "$RESULT_FILE" ]]; then
        # Frog may have stopped waiting and removed the folder. The guide still ends in order.
        { printf '%s\n' "$OUTCOME" > "$RESULT_FILE.tmp" && /bin/mv "$RESULT_FILE.tmp" "$RESULT_FILE"; } 2>/dev/null || true
    fi
    if [[ "$OUTCOME" == failed ]]; then
        say "The change was not verified. Frog will check the actual permissions again."
        pause "Review the error above. Press Enter to close this guide."
    else
        say "This setup window will close automatically."
        /bin/sleep 2
    fi
    exit "$code"
}
trap complete_guide EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

check_access() {
    local value listing
    for value in 0 1; do
        # -k ignores any cached admin login; -ll lists the effective matching
        # policy without executing the command or asking for a password.
        listing=$(/usr/bin/sudo -n -k -ll /usr/bin/pmset -a disablesleep "$value") || return 1
        printf '%s\n' "$listing" | /usr/bin/awk '
            /^[[:space:]]*Options:/ {
                found = 1
                if ($0 !~ /(^|[[:space:],])!authenticate([[:space:],]|$)/ ||
                    $0 ~ /(^|[[:space:],])authenticate([[:space:],]|$)/) bad = 1
            }
            END { exit !(found && !bad) }
        ' || return 1
    done
}

[[ "$(uname -s)" == Darwin ]] || { say "This setup is for macOS."; exit 1; }
[[ "$(id -u)" != 0 ]] || { say "Run this guide as your normal Mac user, not as root."; exit 1; }
[[ "$MODE" == setup || "$MODE" == reset ]] || { say "Use setup or reset."; exit 1; }
ACCOUNT=$(id -un)
[[ "$ACCOUNT" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]] || { say "Use visudo manually for this account name."; exit 1; }
RULE="$ACCOUNT ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
RULE_FILE=/etc/sudoers.d/frog-awake

if [[ "$MODE" == reset ]]; then
    stage "What resetting access does"
    say "Frog restores sleep before opening this guide."
    say "This reset empties only $RULE_FILE, removing the rules in that dedicated Frog file."
    say "It does not edit the main sudoers file. Set up access again whenever you need the feature."
    step "sudo /usr/bin/tee $RULE_FILE < /dev/null"
    say "Your administrator password goes directly to sudo in Terminal, never Frog."
    confirm "Reset stay-awake access?" || { OUTCOME=cancelled; exit 0; }

    stage "Clear Frog's access file"
    if ! /usr/bin/pmset -g | /usr/bin/awk '
        $1 == "SleepDisabled" || $1 == "disablesleep" { if ($2 != "0") exit 1 }
    '; then
        say "Turn off Stay awake before resetting access, then try again."
        exit 1
    fi
    if /usr/bin/sudo /bin/test -f "$RULE_FILE"; then
        /usr/bin/sudo /usr/bin/tee "$RULE_FILE" < /dev/null > /dev/null
    fi

    stage "Verify the reset"
    /usr/bin/sudo /usr/sbin/visudo -c
    /usr/bin/sudo /bin/test ! -s "$RULE_FILE"
    closing "Reset complete"
    say "Frog's access file is now empty. Sleep is allowed."
    if check_access 2>/dev/null; then
        say "Another sudoers rule still allows the power commands; Frog will show their actual availability."
    else
        say "Passwordless stay-awake access is removed. Frog Settings will show Setup needed."
    fi
    OUTCOME=success
    exit 0
fi

stage "Allow two power commands"
say "This guide adds a rule in $RULE_FILE, then verifies both commands without changing sleep."
say "The rule lets Frog turn the system-wide sleep setting on and off when you use Stay awake."
say "This permits only these exact commands, without a password prompt:"
step "/usr/bin/pmset -a disablesleep 0"
step "/usr/bin/pmset -a disablesleep 1"
say "Your admin password is entered directly into sudo in Terminal. Frog never receives it."
say "Setup does not turn Stay awake on. Lock your Mac separately before closing the lid."
say "After successful verification, Frog updates its status and this setup window closes automatically."
confirm "Configure this for $ACCOUNT?" || { OUTCOME=cancelled; exit 0; }

stage "Add the rule with visudo"
say "Add this one line to $RULE_FILE (keep any existing lines):"
say "If this exact line is already there, leave it unchanged."
printf '\n%s\n\n' "$RULE"
say "In the default vi editor: press i, paste the line, press Esc, type :wq, then Enter."
say "visudo checks the syntax before saving. To cancel in vi: Esc, :q!, Enter."
pause "Press Enter to open the editor."
/usr/bin/sudo /bin/mkdir -p /etc/sudoers.d
/usr/bin/sudo /usr/sbin/visudo -f "$RULE_FILE"

stage "Verify access without changing sleep"
/usr/bin/sudo /usr/sbin/visudo -c
# The effective policy decides. sudo also accepts the rule with other spacing, on
# two lines or from another file, so the exact line only chooses the wording.
SAVED=yes
/usr/bin/sudo /usr/bin/grep -Fx "$RULE" "$RULE_FILE" >/dev/null || SAVED=no
if ! check_access; then
    if [[ "$SAVED" == yes ]]; then
        say "Both commands must be allowed without a password. Review the rule and run setup again."
    else
        say "The expected rule was not saved. Re-run this guide to add it."
    fi
    exit 1
fi
closing "Setup complete"
if [[ "$SAVED" == yes ]]; then
    say "Added and verified the two passwordless power permissions in $RULE_FILE."
else
    say "Verified that both power commands are allowed without a password."
    say "The exact line shown before is not in $RULE_FILE; another rule allows them."
fi
say "Your Mac's sleep setting was not changed. Frog is ready to use the feature."
say "With \"Stay awake with the lid closed\" on, every Stay awake session now also works with the lid closed."
say "Frog restores sleep when the session ends, on quit, or below 20% battery when unplugged."
say "You can check or reset this permission on Frog's Stay awake page."
OUTCOME=success
