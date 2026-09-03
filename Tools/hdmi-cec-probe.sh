#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CEC_PROBE_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/volumekey-cec-probe.XXXXXX")"
CEC_PROBE_BINARY="$CEC_PROBE_TEMP_DIR/cec-probe"
CEC_PROBE_PID=""

cleanup_cec_probe() {
    if [[ -n "$CEC_PROBE_PID" ]] && kill -0 "$CEC_PROBE_PID" 2>/dev/null; then
        kill "$CEC_PROBE_PID" 2>/dev/null || true
        wait "$CEC_PROBE_PID" 2>/dev/null || true
    fi
    rm -f "$CEC_PROBE_BINARY"
    rmdir "$CEC_PROBE_TEMP_DIR" 2>/dev/null || true
}
trap cleanup_cec_probe EXIT

restart_corercd() {
    local daemon_pid
    daemon_pid="$(launchctl print system/com.apple.corercd 2>/dev/null | \
        awk '/^[[:space:]]*pid = [0-9]+$/ { print $3; exit }')"
    if [[ ! "$daemon_pid" =~ ^[0-9]+$ ]]; then
        echo "Could not determine corercd's process ID." >&2
        return 1
    fi

    if sudo -n kill -TERM "$daemon_pid" 2>/dev/null; then
        return 0
    fi

    if [[ -t 0 ]]; then
        sudo kill -TERM "$daemon_pid"
    else
        osascript -e \
            "do shell script \"/bin/kill -TERM $daemon_pid\" with administrator privileges" \
            >/dev/null
    fi
}

clang -std=c11 -O2 -Wall -Wextra -Werror \
    -framework CoreFoundation -framework IOKit \
    hdmi-cec-probe.c \
    -o "$CEC_PROBE_BINARY"

if [[ "$#" -eq 1 && "$1" == "--volume-up" ]]; then
    codesign --force --sign - \
        --entitlements cec-probe.entitlements \
        "$CEC_PROBE_BINARY" >/dev/null 2>&1

    "$CEC_PROBE_BINARY" --volume-up &
    CEC_PROBE_PID=$!
    sleep 0.2

    if kill -0 "$CEC_PROBE_PID" 2>/dev/null; then
        echo "Restarting Apple's corercd daemon once to release the CEC interface..."
        if ! restart_corercd; then
            echo "Could not restart corercd; no CEC command was sent." >&2
            exit 1
        fi
    fi

    CEC_PROBE_RESULT=0
    wait "$CEC_PROBE_PID" || CEC_PROBE_RESULT=$?
    CEC_PROBE_PID=""

    for _ in {1..50}; do
        if launchctl print system/com.apple.corercd 2>/dev/null | \
            grep -q 'state = running'; then
            break
        fi
        sleep 0.1
    done

    exit "$CEC_PROBE_RESULT"
fi

"$CEC_PROBE_BINARY" "$@"
