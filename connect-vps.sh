#!/usr/bin/env bash
# connect-vps.sh - Connect to ANY VPS from ANY terminal, with one command.
#
# What this does, in order:
#   1. Makes sure ssh and ssh-keygen are available.
#   2. Reuses your existing ed25519 key, or generates one if missing.
#      Only the public key (.pub) is ever copied to a VPS.
#      A private key is never printed, copied, logged, or stored anywhere
#      except the key file you already own in ~/.ssh.
#   3. Copies the public key to the VPS (first time only).
#      If the VPS asks for a password at that prompt, you type it
#      yourself, in your own terminal, at that prompt. This script
#      never asks for, stores, logs, or prints a password, and never
#      puts a password in a file, an environment variable, or a command.
#   4. Adds a short alias (Host block) to ~/.ssh/config, backed up first.
#      An existing Host block with the same name is replaced in place,
#      never duplicated. All other Host entries are preserved.
#   5. Tests the alias with: ssh <alias> 'echo VPS-CONNECT-OK'
#
# Usage:
#   ./connect-vps.sh --name vps2 --host <VPS-IP> [--user root] [--port 22]
#   ./connect-vps.sh                      # interactive prompts
#   ./connect-vps.sh --dry-run --name vps2 --host <VPS-IP>
#   ./connect-vps.sh --help
#
# No dependencies beyond standard OpenSSH (ssh, ssh-keygen, ssh-copy-id)
# and coreutils. Works on PC terminals and phone terminals (e.g. Termux)
# because it uses $HOME/.ssh, never a hardcoded /root or /home/user path.

# Do not abort on the first failing test command; errors are handled
# explicitly so the user gets a plain report instead of a cryptic exit.
set -u

PROG="connect-vps.sh"
NAME=""
HOST=""
USER_NAME="root"
PORT="22"
KEY=""
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $PROG [options]

Options:
  --name NAME     Short alias, e.g. vps2 (letters, digits, - and _ only)
  --host HOST     VPS IP address or hostname (required)
  --user USER     SSH user on the VPS (default: root)
  --port PORT     SSH port (default: 22, range 1-65535)
  --key PATH      Private key file (default: ~/.ssh/id_ed25519)
  --dry-run       Print every step that would run; change nothing,
                  contact no VPS, generate no key
  --help          Show this help and exit

Examples:
  $PROG --name vps2 --host <VPS-IP>
  $PROG --name vps2 --host <VPS-IP> --user ubuntu --port 2222
  $PROG --dry-run --name vps2 --host <VPS-IP>
  $PROG

Interactive mode: if --name or --host is missing (and --help/--dry-run
is not the only thing requested), the script prompts for them.
The VPS password, if prompted by ssh-copy-id / ssh on first copy,
is typed only by you, in your own terminal, at that prompt.
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

# --- Parse arguments -------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --name)
            [ $# -ge 2 ] || fail "--name needs a value"
            NAME="$2"; shift 2 ;;
        --name=*)
            NAME="${1#--name=}"; shift ;;
        --host)
            [ $# -ge 2 ] || fail "--host needs a value"
            HOST="$2"; shift 2 ;;
        --host=*)
            HOST="${1#--host=}"; shift ;;
        --user)
            [ $# -ge 2 ] || fail "--user needs a value"
            USER_NAME="$2"; shift 2 ;;
        --user=*)
            USER_NAME="${1#--user=}"; shift ;;
        --port)
            [ $# -ge 2 ] || fail "--port needs a value"
            PORT="$2"; shift 2 ;;
        --port=*)
            PORT="${1#--port=}"; shift ;;
        --key)
            [ $# -ge 2 ] || fail "--key needs a value"
            KEY="$2"; shift 2 ;;
        --key=*)
            KEY="${1#--key=}"; shift ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        --help|-h)
            usage; exit 0 ;;
        *)
            fail "Unknown argument: $1 (see --help)" ;;
    esac
done

# --- Interactive prompts for missing required values -----------------------
# In dry-run mode, missing values are still prompted for, because the
# dry-run output is only meaningful for a specific name/host. If stdin
# is not a terminal, prompting fails cleanly instead of hanging.
prompt_if_missing() {
    if [ -z "$NAME" ]; then
        printf 'VPS alias (e.g. vps2): '
        IFS= read -r NAME || fail "Could not read alias"
    fi
    if [ -z "$HOST" ]; then
        printf 'VPS IP or hostname: '
        IFS= read -r HOST || fail "Could not read host"
    fi
    if [ -z "$USER_NAME" ]; then
        USER_NAME="root"
    fi
    if [ -z "$PORT" ]; then
        PORT="22"
    fi
}
prompt_if_missing

# --- Validation (never run ssh with unvalidated input) ---------------------
case "$NAME" in
    ''|*[!A-Za-z0-9_-]*)
        fail "Unsafe alias '$NAME': use letters, digits, - and _ only" ;;
esac

case "$HOST" in
    ''|*[[:space:]]*|*[\;\&\|\$\`\"\'\\\<\>]*)
        fail "Unsafe host: host must be a plain IP or hostname, no spaces or shell characters" ;;
esac

case "$USER_NAME" in
    ''|*[[:space:]]*|*[\;\&\|\$\`\"\'\\\<\>]*)
        fail "Unsafe user: use a plain SSH username, no spaces or shell characters" ;;
esac

case "$PORT" in
    ''|*[!0-9]*)
        fail "Port must be a number between 1 and 65535" ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    fail "Port must be a number between 1 and 65535"
fi

# --- Defaults and paths ------------------------------------------------------
# Expand a leading ~/ in --key, and default to ~/.ssh/id_ed25519.
if [ -z "$KEY" ]; then
    KEY="$HOME/.ssh/id_ed25519"
else
    case "$KEY" in
        \~/*) KEY="$HOME/${KEY#\~/}" ;;
        \~)   KEY="$HOME" ;;
    esac
fi
SSH_DIR="$HOME/.ssh"
CONFIG_FILE="$SSH_DIR/config"
PUB_KEY="$KEY.pub"

# --- Tool checks -------------------------------------------------------------
missing=""
for tool in ssh ssh-keygen; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing="$missing $tool"
    fi
done
if [ -n "$missing" ]; then
    printf 'Error: missing required tool(s):%s\n' "$missing" >&2
    printf 'Install hint:\n' >&2
    printf '  Termux:           pkg install openssh\n' >&2
    printf '  Debian / Ubuntu:  sudo apt install openssh-client\n' >&2
    printf '  macOS:            usually preinstalled (ssh / ssh-keygen)\n' >&2
    printf 'This script does not install anything automatically.\n' >&2
    exit 1
fi
HAVE_COPY_ID=0
if command -v ssh-copy-id >/dev/null 2>&1; then
    HAVE_COPY_ID=1
fi

# --- Dry run: print everything, change nothing -------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    printf 'Dry run - nothing will be changed, no VPS will be contacted.\n'
    if [ -f "$KEY" ]; then
        printf 'Step 1 - Key: reuse existing key %s (no new key)\n' "$KEY"
    else
        printf 'Step 1 - Key: generate ed25519 key %s with ssh-keygen\n' "$KEY"
        printf '         (you would be prompted for a passphrase; empty means no passphrase prompt on connect)\n'
    fi
    printf 'Step 2 - SSH directory: ensure %s exists with mode 700\n' "$SSH_DIR"
    if [ -f "$CONFIG_FILE" ]; then
        printf 'Step 3 - Config backup: copy %s to %s.bak-<date> before editing\n' "$CONFIG_FILE" "$CONFIG_FILE"
    else
        printf 'Step 3 - Config backup: no existing %s, no backup needed\n' "$CONFIG_FILE"
    fi
    if [ "$HAVE_COPY_ID" -eq 1 ]; then
        printf 'Step 4 - Copy public key: ssh-copy-id -i %s -p %s %s@%s\n' "$PUB_KEY" "$PORT" "$USER_NAME" "$HOST"
    else
        printf 'Step 4 - Copy public key (ssh-copy-id not found, fallback): cat %s | ssh -p %s %s@%s %s\n' "$PUB_KEY" "$PORT" "$USER_NAME" "$HOST" "'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys'"
    fi
    printf '         (if the VPS asks for a password, you type it in your own terminal at that prompt; it is never stored or printed)\n'
    printf 'Step 5 - Config block to add (replacing any existing Host %s block, preserving all others):\n' "$NAME"
    printf '  Host %s\n' "$NAME"
    printf '    HostName %s\n' "$HOST"
    printf '    User %s\n' "$USER_NAME"
    printf '    Port %s\n' "$PORT"
    printf '    IdentityFile %s\n' "$KEY"
    printf 'Step 6 - Test: ssh -o ConnectTimeout=10 -p %s %s %s\n' "$PORT" "$NAME" "'echo VPS-CONNECT-OK'"
    printf 'After that, connect any time with: ssh %s\n' "$NAME"
    exit 0
fi

# --- Real run ---------------------------------------------------------------
printf 'VPS alias: %s\n' "$NAME"
printf 'VPS host:  %s (user %s, port %s)\n' "$HOST" "$USER_NAME" "$PORT"

# Ensure ~/.ssh exists with mode 700.
if [ ! -d "$SSH_DIR" ]; then
    mkdir -p "$SSH_DIR" || fail "Could not create $SSH_DIR"
fi
chmod 700 "$SSH_DIR" || fail "Could not set mode 700 on $SSH_DIR"

# Key: reuse if present, generate if missing. Never overwrite.
if [ -f "$KEY" ]; then
    printf 'Key: reusing existing key %s (not overwritten)\n' "$KEY"
else
    printf 'Key: generating ed25519 key %s\n' "$KEY"
    printf 'You will be prompted for a passphrase. Empty means no passphrase prompt on connect.\n'
    ssh-keygen -t ed25519 -f "$KEY" || fail "ssh-keygen failed"
fi
if [ ! -f "$PUB_KEY" ]; then
    fail "Public key not found: $PUB_KEY"
fi
chmod 600 "$KEY" 2>/dev/null || true

# Backup existing config before editing it.
if [ -f "$CONFIG_FILE" ]; then
    STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)-$$"
    BACKUP="$CONFIG_FILE.bak-$STAMP"
    cp "$CONFIG_FILE" "$BACKUP" || fail "Could not back up $CONFIG_FILE"
    printf 'Config backup: %s\n' "$BACKUP"
fi

# Copy the public key to the VPS. Only the .pub file is sent.
printf 'Copying public key to %s@%s (first time only)...\n' "$USER_NAME" "$HOST"
printf 'If the VPS asks for a password, type it in your own terminal at that prompt. It is never stored or printed by this script.\n'
if [ "$HAVE_COPY_ID" -eq 1 ]; then
    if ! ssh-copy-id -i "$PUB_KEY" -p "$PORT" "$USER_NAME@$HOST"; then
        fail "ssh-copy-id failed. Likely causes: wrong IP/host, wrong user, or the password was not accepted on first copy. No config change was made yet."
    fi
else
    if ! cat "$PUB_KEY" | ssh -p "$PORT" "$USER_NAME@$HOST" 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys'; then
        fail "Key copy failed (fallback path). Likely causes: wrong IP/host, wrong user, or the password was not accepted on first copy. No config change was made yet."
    fi
fi
printf 'Public key copied.\n'

# Add/replace the Host block, preserving all other entries.
# Remove any existing Host block whose Host line names this alias,
# then append the new block. This never duplicates the alias.
TMP_CONFIG="$CONFIG_FILE.tmp.$$"
if [ -f "$CONFIG_FILE" ]; then
    # Remove any existing Host block naming this alias, preserving
    # all other entries. A block runs from its Host line until the
    # next Host line (or end of file).
    awk -v name="$NAME" '
        BEGIN { skip = 0 }
        /^Host[ \t]/ {
            skip = 0
            for (i = 2; i <= NF; i++) {
                if ($i == name) { skip = 1 }
            }
            if (skip) { next }
        }
        skip { next }
        { print }
    ' "$CONFIG_FILE" > "$TMP_CONFIG" || fail "Could not filter existing config"
    mv "$TMP_CONFIG" "$CONFIG_FILE" || fail "Could not update config"
else
    : > "$CONFIG_FILE" || fail "Could not create $CONFIG_FILE"
fi
chmod 600 "$CONFIG_FILE" 2>/dev/null || true
{
    printf '\nHost %s\n' "$NAME"
    printf '    HostName %s\n' "$HOST"
    printf '    User %s\n' "$USER_NAME"
    printf '    Port %s\n' "$PORT"
    printf '    IdentityFile %s\n' "$KEY"
} >> "$CONFIG_FILE" || fail "Could not append alias to config"
printf 'Alias added: ssh %s\n' "$NAME"

# Test the alias.
printf 'Testing alias (ssh %s)...\n' "$NAME"
if ssh -o ConnectTimeout=10 -p "$PORT" "$NAME" 'echo VPS-CONNECT-OK'; then
    printf 'Success: connected to %s via alias %s.\n' "$HOST" "$NAME"
    printf 'Connect any time with: ssh %s\n' "$NAME"
    exit 0
else
    printf 'Test failed: could not connect via alias %s.\n' "$NAME" >&2
    printf 'Likely causes: wrong IP/host, wrong user, wrong port, or the key is not in ~/.ssh/authorized_keys on the VPS.\n' >&2
    printf 'The alias was still added to %s, so fix the VPS side and run: ssh %s\n' "$CONFIG_FILE" "$NAME" >&2
    exit 1
fi
