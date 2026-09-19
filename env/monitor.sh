#!/system/bin/sh
# ============================================================
#  Cloudphone Monitor v2
#  - Real-time (1s) watchdog
#  - UDP + CPU in-game detection
#  - Fixed CPU subshell bug
#  - Cached account detection
# ============================================================

# ----------------------- Configuration ----------------------
WEBHOOK_URL="https://discord.com/api/webhooks/1478853919223451701/QBtFbDgqCs6xPrLLTjgCuzGyIT9uJpOD1LIubL5wIEF5Lm-On7wzyZ9UP2qMS2GmAnBK"

TARGET_PACKAGE="free.nokaA"
TARGET_ACTIVITY="com.roblox.client.startup.LauncherAliasMain"
TARGET_RUNNING_ACTIVITY="com.roblox.client.ActivityNativeMain"

ROBLOX_STORAGE="/data/data/free.nokaA/files/appData/LocalStorage/appStorage.json"
ROBLOX_GAME_ID="1730877806"

SCREEN_PATH="/data/local/tmp/screen.png"
UI_DUMP_PATH="/data/local/tmp/ui.xml"
ACCOUNTS_FILE="/data/local/tmp/account.txt"

CURL="/data/data/com.termux/files/usr/bin/curl"
PYTHON="/data/data/com.termux/files/usr/bin/python3"

# Timing
CHECK_INTERVAL=1          # watchdog poll target
REPORT_INTERVAL=300
JOIN_WAIT=8
JOIN_TIMEOUT=45
RECOVERY_WAIT=10
REJOIN_COOLDOWN=30        # minimum seconds between join attempts
OUT_OF_GAME_GRACE=15      # seconds of "out of game" before rejoining
UI_CHECK_INTERVAL=3
ACCOUNT_CACHE_TTL=10      # seconds before re-running account python

# Detection thresholds
UDP_CHECK_ENABLED=1
CPU_INGAME_THRESHOLD=25   # % of one core

# Debug
STATUS_EVERY=5            # heartbeat interval (seconds)

# ------------------------- State -----------------------------
PREVIOUS_INSTANCE_STATUS=""
PREVIOUS_ACCOUNT=""
GAME_STATE="UNKNOWN"
LAST_JOIN_TIME=0
RECOVERY_RUNNING=0
LOGIN_ATTEMPTED=0
ACCOUNT_SEEN_THIS_SESSION=0
NOT_IN_GAME_STREAK=0
LAST_CPU_TICKS=0
LAST_CPU_SAMPLE_TS=0
LAST_CPU_PCT=0
LAST_UDP=0
LAST_STATUS_TS=0

# Cached account
CACHED_ACCOUNT=""
CACHED_ACCOUNT_TS=0

# ============================================================
#  System stat helpers
# ============================================================
get_cpu_usage() {
    CPU_LINE=$(top -n 1 -b 2>/dev/null | grep -i "cpu" | head -1)
    if [ -z "$CPU_LINE" ]; then
        echo "N/A"; return
    fi
    TOTAL=$(echo "$CPU_LINE" | grep -o '[0-9]*%cpu' | head -1 | tr -d '%cpu')
    IDLE=$(echo "$CPU_LINE" | grep -o '[0-9]*%idle' | head -1 | tr -d '%idle')
    if [ -n "$TOTAL" ] && [ -n "$IDLE" ] && [ "$TOTAL" -gt 0 ] 2>/dev/null; then
        USED=$(( (TOTAL - IDLE) * 100 / TOTAL ))
        echo "${USED}%"
    else
        echo "$CPU_LINE"
    fi
}

get_cpu_temperature() {
    for FILE in /sys/class/thermal/thermal_zone*/temp; do
        [ -f "$FILE" ] || continue
        VALUE=$(cat "$FILE" 2>/dev/null)
        if [ -n "$VALUE" ] && [ "$VALUE" -gt 1000 ] 2>/dev/null; then
            echo "$((VALUE / 1000))°C"; return
        fi
    done
    echo "N/A"
}

get_battery() {
    BATTERY_LEVEL=$(/system/bin/dumpsys battery 2>/dev/null | grep "level:" | head -1 | awk '{print $2}')
    [ -n "$BATTERY_LEVEL" ] && echo "${BATTERY_LEVEL}%" || echo "N/A"
}

get_uptime() {
    UPTIME_SECONDS=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    [ -z "$UPTIME_SECONDS" ] && { echo "N/A"; return; }
    DAYS=$((UPTIME_SECONDS / 86400))
    HOURS=$(((UPTIME_SECONDS % 86400) / 3600))
    MINUTES=$(((UPTIME_SECONDS % 3600) / 60))
    if [ "$DAYS" -gt 0 ]; then
        echo "${DAYS}d ${HOURS}h ${MINUTES}m"
    elif [ "$HOURS" -gt 0 ]; then
        echo "${HOURS}h ${MINUTES}m"
    else
        echo "${MINUTES}m"
    fi
}

get_storage() {
    STORAGE_INFO=$(/system/bin/df -h /data 2>/dev/null | tail -1)
    if [ -n "$STORAGE_INFO" ]; then
        USED=$(echo "$STORAGE_INFO" | awk '{print $3}')
        TOTAL=$(echo "$STORAGE_INFO" | awk '{print $2}')
        PERCENT=$(echo "$STORAGE_INFO" | awk '{print $5}')
        echo "${USED} / ${TOTAL} (${PERCENT})"
    else
        echo "N/A"
    fi
}

get_ram() {
    TOTAL_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
    AVAIL_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "$TOTAL_KB" ] && [ -n "$AVAIL_KB" ]; then
        TOTAL_MB=$((TOTAL_KB / 1024))
        USED_MB=$(((TOTAL_KB - AVAIL_KB) / 1024))
        if [ "$TOTAL_MB" -gt 0 ]; then
            PCT=$((USED_MB * 100 / TOTAL_MB))
            echo "${USED_MB} MB / ${TOTAL_MB} MB (${PCT}%)"
            return
        fi
    fi
    echo "N/A"
}

# ============================================================
#  Process detection
# ============================================================
is_process_alive() {
    /system/bin/pidof "$TARGET_PACKAGE" >/dev/null 2>&1
}

get_roblox_pid() {
    /system/bin/pidof "$TARGET_PACKAGE" 2>/dev/null | awk '{print $1}'
}

get_instance_status() {
    if is_process_alive; then
        echo "Running"
    else
        echo "Closed"
    fi
}

# ============================================================
#  In-game detection  (UDP + CPU)
# ============================================================
get_roblox_uid() {
    stat -c %u "/data/data/$TARGET_PACKAGE" 2>/dev/null
}

count_conns_for_uid() {
    FILE="$1"; UID="$2"
    [ -z "$UID" ] && { echo 0; return; }
    [ -r "$FILE" ] || { echo 0; return; }
    awk -v u="$UID" '$8 == u {c++} END {print c+0}' "$FILE" 2>/dev/null
}

is_in_game_network() {
    [ "$UDP_CHECK_ENABLED" -eq 1 ] || return 1
    UID=$(get_roblox_uid)
    [ -z "$UID" ] && return 1
    [ "$(count_conns_for_uid /proc/net/udp  "$UID")" -gt 0 ] && return 0
    [ "$(count_conns_for_uid /proc/net/udp6 "$UID")" -gt 0 ] && return 0
    return 1
}

# Updates global ROBLOX_CPU_PCT. Do NOT call in a subshell.
update_roblox_cpu_pct() {
    NOW=$(/system/bin/date +%s)
    P=$(get_roblox_pid)

    if [ -z "$P" ] || [ ! -r "/proc/$P/stat" ]; then
        LAST_CPU_TICKS=0
        LAST_CPU_SAMPLE_TS=0
        ROBLOX_CPU_PCT=0
        return
    fi

    TICKS=$(awk '{print $14 + $15}' "/proc/$P/stat" 2>/dev/null)
    [ -z "$TICKS" ] && TICKS=0

    if [ "$LAST_CPU_SAMPLE_TS" -eq 0 ]; then
        LAST_CPU_TICKS="$TICKS"
        LAST_CPU_SAMPLE_TS="$NOW"
        ROBLOX_CPU_PCT=0
        return
    fi

    DT=$((NOW - LAST_CPU_SAMPLE_TS))
    if [ "$DT" -le 0 ]; then
        ROBLOX_CPU_PCT="$LAST_CPU_PCT"
        return
    fi

    DD=$((TICKS - LAST_CPU_TICKS))
    [ "$DD" -lt 0 ] && DD=0

    LAST_CPU_TICKS="$TICKS"
    LAST_CPU_SAMPLE_TS="$NOW"

    ROBLOX_CPU_PCT=$((DD / DT))
    LAST_CPU_PCT="$ROBLOX_CPU_PCT"
}

reset_cpu_sampling() {
    LAST_CPU_TICKS=0
    LAST_CPU_SAMPLE_TS=0
    LAST_CPU_PCT=0
    ROBLOX_CPU_PCT=0
}

is_in_game() {
    CPU=$1
    UDP=$2
    [ "$UDP" -eq 1 ] && return 0
    [ "$CPU" -ge "$CPU_INGAME_THRESHOLD" ] 2>/dev/null && return 0
    return 1
}

# ============================================================
#  Cached account detection
# ============================================================
get_roblox_account_raw() {
    if [ ! -f "$ROBLOX_STORAGE" ]; then
        echo "N/A|N/A"
        return
    fi

    RESULT=$("$PYTHON" - "$ROBLOX_STORAGE" 2>/dev/null <<'PY'
import sys, json, re

path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8', errors='ignore') as f:
        raw = f.read()
except Exception:
    print("N/A|N/A"); sys.exit(0)

accounts = []
seen = set()

def push(username, uid, show_picker=False, sign_in=0, sign_out=None):
    if not username or uid is None:
        return
    uid = str(uid)
    if uid in seen:
        return
    seen.add(uid)
    accounts.append({
        "username": str(username),
        "user_id": uid,
        "picker": bool(show_picker),
        "sign_in": int(sign_in or 0),
        "sign_out": sign_out,
    })

def add_from_dict(d):
    if not isinstance(d, dict):
        return
    uid = (d.get('userId') or d.get('UserId')
           or d.get('user_id') or d.get('userID'))
    uname = (d.get('username') or d.get('Username')
             or d.get('userIdentifier') or d.get('displayName')
             or d.get('DisplayName') or d.get('name'))
    if uid is None or not uname:
        return
    push(
        uname, uid,
        show_picker=d.get('showInAccountPicker', False),
        sign_in=d.get('signInTimestamp') or 0,
        sign_out=d.get('signOutTimestamp'),
    )

def walk(obj, depth=0):
    if depth > 25:
        return
    if isinstance(obj, dict):
        add_from_dict(obj)
        for v in obj.values():
            walk(v, depth + 1)
    elif isinstance(obj, list):
        for item in obj:
            walk(item, depth + 1)
    elif isinstance(obj, str):
        s = obj.strip()
        if not s:
            return
        candidates = [s]
        if '\\"' in s:
            candidates.append(s.replace('\\"', '"'))
        if '\\/' in s:
            candidates.append(s.replace('\\/', '/'))
        for c in candidates:
            if not (c.startswith('{') or c.startswith('[')):
                continue
            try:
                walk(json.loads(c), depth + 1)
                break
            except Exception:
                continue

try:
    outer = json.loads(raw)
    walk(outer)
except Exception:
    pass

if not accounts:
    normalized = raw.replace('\\"', '"').replace('\\/', '/')
    obj_re = re.compile(r'\{[^{}]{0,800}\}')
    for m in obj_re.finditer(normalized):
        blob = m.group(0)
        uid_m = re.search(r'"(?:userId|user_id|userID)"\s*:\s*"?(\d+)"?', blob)
        name_m = re.search(
            r'"(?:username|userIdentifier|displayName)"\s*:\s*"([^"]+)"',
            blob)
        if uid_m and name_m:
            picker_m = re.search(
                r'"showInAccountPicker"\s*:\s*(true|false)', blob)
            signout_m = re.search(r'"signOutTimestamp"\s*:\s*(\d+)', blob)
            signin_m = re.search(r'"signInTimestamp"\s*:\s*(\d+)', blob)
            push(
                name_m.group(1), uid_m.group(1),
                show_picker=(picker_m and picker_m.group(1) == 'true'),
                sign_in=(int(signin_m.group(1)) if signin_m else 0),
                sign_out=(int(signout_m.group(1)) if signout_m else None),
            )

accounts = [a for a in accounts if a["sign_out"] is None]

if not accounts:
    print("N/A|N/A"); sys.exit(0)

picker = [a for a in accounts if a["picker"]]
if picker:
    sel = picker[-1]
else:
    sel = sorted(accounts, key=lambda x: x["sign_in"], reverse=True)[0]

print(f"{sel['username']}|{sel['user_id']}")
PY
)

    if [ -n "$RESULT" ] && echo "$RESULT" | grep -q '|'; then
        echo "$RESULT"
    else
        echo "N/A|N/A"
    fi
}

# Returns cached account, refreshing at most every ACCOUNT_CACHE_TTL seconds.
get_roblox_account() {
    NOW=$(/system/bin/date +%s)
    if [ -n "$CACHED_ACCOUNT" ] \
       && [ $((NOW - CACHED_ACCOUNT_TS)) -lt "$ACCOUNT_CACHE_TTL" ]; then
        echo "$CACHED_ACCOUNT"
        return
    fi

    CACHED_ACCOUNT=$(get_roblox_account_raw)
    CACHED_ACCOUNT_TS=$NOW
    echo "$CACHED_ACCOUNT"
}

# ============================================================
#  UI automation helpers  (auto-login only)
# ============================================================
UI_DUMP_TS=0

ui_dump() {
    /system/bin/uiautomator dump "$UI_DUMP_PATH" >/dev/null 2>&1
    UI_DUMP_TS=$(/system/bin/date +%s)
    [ -f "$UI_DUMP_PATH" ]
}

ui_find_fields() {
    "$PYTHON" - "$UI_DUMP_PATH" <<'PY'
import sys, re
import xml.etree.ElementTree as ET

try:
    tree = ET.parse(sys.argv[1])
except Exception:
    sys.exit(0)

def center(bounds):
    m = re.findall(r'\d+', bounds or '')
    if len(m) == 4:
        return (int(m[0]) + int(m[2])) // 2, (int(m[1]) + int(m[3])) // 2
    return None

username = password = login = None
edit_fields = []

for node in tree.iter('node'):
    cls   = node.get('class', '') or ''
    text  = (node.get('text', '') or '').strip()
    desc  = (node.get('content-desc', '') or '').strip()
    rid   = node.get('resource-id', '') or ''
    bnd   = node.get('bounds', '')
    combo = (text + ' ' + desc + ' ' + rid).lower()

    if 'EditText' in cls:
        edit_fields.append((combo, bnd))

    if login is None and 'EditText' not in cls:
        if (re.search(r'\blog ?in\b', combo)
                or 'sign in' in combo or 'signin' in combo
                or 'btn_login' in combo or 'button_login' in combo):
            c = center(bnd)
            if c: login = c

for combo, bnd in edit_fields:
    c = center(bnd)
    if not c: continue
    if username is None and re.search(r'user|email|name', combo):
        username = c
        continue
    if password is None and re.search(r'pass', combo):
        password = c
        continue

if not username and not password and len(edit_fields) >= 2:
    c0 = center(edit_fields[0][1]); c1 = center(edit_fields[1][1])
    username = username or c0
    password = password or c1
elif username and not password:
    for combo, bnd in edit_fields:
        c = center(bnd)
        if c and c != username:
            password = c
            break
elif password and not username:
    for combo, bnd in edit_fields:
        c = center(bnd)
        if c and c != password:
            username = c
            break

if username: print(f"USERNAME {username[0]} {username[1]}")
if password: print(f"PASSWORD {password[0]} {password[1]}")
if login:    print(f"LOGIN {login[0]} {login[1]}")
PY
}

is_login_screen() {
    ui_dump || return 1
    [ ! -f "$UI_DUMP_PATH" ] && return 1

    HAS_PW=0
    grep -qE 'text="Password"' "$UI_DUMP_PATH" && HAS_PW=1
    grep -qE 'resource-id="[^"]*edit_password' "$UI_DUMP_PATH" && HAS_PW=1
    grep -qE 'password="true"' "$UI_DUMP_PATH" && HAS_PW=1

    HAS_USER=0
    grep -qE 'text="(Username|Email|username|email)"' "$UI_DUMP_PATH" && HAS_USER=1
    grep -qE 'resource-id="[^"]*edit_username' "$UI_DUMP_PATH" && HAS_USER=1

    HAS_BTN=0
    grep -qE 'text="(Log ?In|Login|Sign ?In)"' "$UI_DUMP_PATH" && HAS_BTN=1
    grep -qE 'resource-id="[^"]*(btn_login|button_login)' "$UI_DUMP_PATH" && HAS_BTN=1

    [ "$HAS_PW" -eq 1 ] && [ "$HAS_USER" -eq 1 ] && [ "$HAS_BTN" -eq 1 ]
}

input_escape() {
    echo "$1" | sed 's/ /%s/g'
}

auto_login() {
    if [ ! -f "$ACCOUNTS_FILE" ]; then
        echo "Auto-login: $ACCOUNTS_FILE not found."
        return 1
    fi
    LINE=$(head -n 1 "$ACCOUNTS_FILE")
    [ -z "$LINE" ] && { echo "Auto-login: accounts file is empty."; return 1; }
    USERNAME=$(echo "$LINE" | cut -d: -f1)
    PASSWORD=$(echo "$LINE" | cut -d: -f2-)
    [ -z "$USERNAME" ] && return 1
    [ -z "$PASSWORD" ] && return 1

    echo "Auto-login: trying account '$USERNAME'"
    ui_dump || { echo "Auto-login: uiautomator dump failed."; return 1; }

    FIELDS=$(ui_find_fields)
    if [ -z "$FIELDS" ]; then
        echo "Auto-login: could not locate fields."
        return 1
    fi

    echo "$FIELDS" | while read -r TYPE X Y; do
        case "$TYPE" in
            USERNAME)
                /system/bin/input tap "$X" "$Y"
                sleep 1
                /system/bin/input text "$(input_escape "$USERNAME")"
                sleep 1
                ;;
            PASSWORD)
                /system/bin/input tap "$X" "$Y"
                sleep 1
                /system/bin/input text "$(input_escape "$PASSWORD")"
                sleep 1
                ;;
            LOGIN)
                /system/bin/input tap "$X" "$Y"
                echo "Auto-login: tapped login button."
                ;;
        esac
    done

    if ! echo "$FIELDS" | grep -q '^LOGIN '; then
        echo "Auto-login: no login button, sending ENTER."
        /system/bin/input keyevent 66
    fi

    return 0
}

# ============================================================
#  Launch / join
# ============================================================
launch_instance() {
    ACCOUNT_SEEN_THIS_SESSION=0
    LOGIN_ATTEMPTED=0
    UI_DUMP_TS=0
    reset_cpu_sampling
    CACHED_ACCOUNT=""
    CACHED_ACCOUNT_TS=0

    echo "Launching $TARGET_PACKAGE..."
    /system/bin/am start -n "$TARGET_PACKAGE/$TARGET_ACTIVITY" >/dev/null 2>&1

    COUNT=0
    while [ "$COUNT" -lt 30 ]; do
        if is_process_alive; then
            echo "Roblox process started."
            return 0
        fi
        sleep 1
        COUNT=$((COUNT + 1))
    done
    echo "Roblox process failed to start."
    return 1
}

wait_for_account() {
    echo "Waiting for Roblox account..."
    COUNT=0
    while [ "$COUNT" -lt 60 ]; do
        CACHED_ACCOUNT_TS=0
        ACCOUNT_DATA=$(get_roblox_account)
        U=$(echo "$ACCOUNT_DATA" | cut -d'|' -f1)
        if [ -n "$U" ] && [ "$U" != "N/A" ]; then
            ACCOUNT_SEEN_THIS_SESSION=1
            echo "Roblox account detected: $U"
            return 0
        fi

        if [ "$ACCOUNT_SEEN_THIS_SESSION" -eq 0 ] \
           && [ "$LOGIN_ATTEMPTED" -eq 0 ] \
           && [ "$COUNT" -ge 5 ]; then
            if is_login_screen; then
                echo "Login screen detected (no prior session)."
                auto_login
                LOGIN_ATTEMPTED=1
            fi
        fi

        sleep 1
        COUNT=$((COUNT + 1))
    done
    echo "Roblox account was not detected."
    return 1
}

send_join_intent() {
    /system/bin/am start \
        -a android.intent.action.VIEW \
        -d "roblox://placeId=$ROBLOX_GAME_ID" \
        >/dev/null 2>&1
    LAST_JOIN_TIME=$(/system/bin/date +%s)
    UI_DUMP_TS=0
}

join_game() {
    if ! is_process_alive; then
        echo "Cannot join: Roblox is not running."
        return 1
    fi
    echo "Waiting ${JOIN_WAIT}s before game join..."
    sleep "$JOIN_WAIT"
    if ! is_process_alive; then
        echo "Roblox stopped before game join."
        return 1
    fi
    echo "Joining Roblox game: $ROBLOX_GAME_ID"
    send_join_intent
    GAME_STATE="JOINING"
    echo "Game join intent sent."
    return 0
}

wait_for_game_start() {
    echo "Waiting for game connection..."
    COUNT=0
    while [ "$COUNT" -lt "$JOIN_TIMEOUT" ]; do
        if ! is_process_alive; then
            echo "Roblox died during join."
            GAME_STATE="NOT_IN_GAME"
            return 1
        fi

        update_roblox_cpu_pct
        CPU_NOW="$ROBLOX_CPU_PCT"
        UDP_NOW=0
        is_in_game_network && UDP_NOW=1

        if is_in_game "$CPU_NOW" "$UDP_NOW"; then
            GAME_STATE="IN_GAME"
            echo "Connected (cpu=${CPU_NOW}% udp=${UDP_NOW})."
            return 0
        fi

        sleep 1
        COUNT=$((COUNT + 1))
    done
    GAME_STATE="JOINING"
    echo "Join window elapsed without signal."
    return 0
}

start_and_join() {
    if ! is_process_alive; then
        launch_instance || return 1
    fi
    wait_for_account || return 1
    join_game || return 1
    wait_for_game_start
    return 0
}

# ============================================================
#  Recovery
# ============================================================
force_rejoin() {
    [ "$RECOVERY_RUNNING" -eq 1 ] && return 0
    RECOVERY_RUNNING=1

    echo "=============================="
    echo "ROBLOX GAME RECOVERY"
    echo "=============================="
    echo "Waiting ${RECOVERY_WAIT}s..."
    sleep "$RECOVERY_WAIT"

    if ! is_process_alive; then
        echo "Roblox is closed — relaunching."
        launch_instance || { RECOVERY_RUNNING=0; return 1; }
        wait_for_account || { RECOVERY_RUNNING=0; return 1; }
        join_game || { RECOVERY_RUNNING=0; return 1; }
        wait_for_game_start
        RECOVERY_RUNNING=0
        return 0
    fi

    echo "Roblox running — re-sending join intent."
    send_join_intent
    GAME_STATE="JOINING"
    sleep "$JOIN_TIMEOUT"

    update_roblox_cpu_pct
    CPU_NOW="$ROBLOX_CPU_PCT"
    UDP_NOW=0
    is_in_game_network && UDP_NOW=1
    if is_in_game "$CPU_NOW" "$UDP_NOW"; then
        GAME_STATE="IN_GAME"
        RECOVERY_RUNNING=0
        return 0
    fi

    if ! is_process_alive; then
        echo "Roblox died — relaunching cleanly."
        /system/bin/am force-stop "$TARGET_PACKAGE" >/dev/null 2>&1
        sleep 3
        launch_instance || { RECOVERY_RUNNING=0; return 1; }
        wait_for_account || { RECOVERY_RUNNING=0; return 1; }
        join_game || { RECOVERY_RUNNING=0; return 1; }
        wait_for_game_start
    fi

    RECOVERY_RUNNING=0
    return 0
}

# ============================================================
#  Discord reporting
# ============================================================
send_report() {
    echo "Collecting report data..."
    UNIX_TIME=$(/system/bin/date +%s)
    DISCORD_TIME="<t:${UNIX_TIME}:F>"

    CPU_PERCENT=$(get_cpu_usage)
    RAM_INFO=$(get_ram)
    TEMPERATURE=$(get_cpu_temperature)
    BATTERY=$(get_battery)
    STORAGE=$(get_storage)
    UPTIME=$(get_uptime)
    APP_STATUS=$(get_instance_status)

    CACHED_ACCOUNT_TS=0
    ACCOUNT_DATA=$(get_roblox_account)
    ROBLOX_USERNAME=$(echo "$ACCOUNT_DATA" | cut -d'|' -f1)
    ROBLOX_USER_ID=$(echo "$ACCOUNT_DATA" | cut -d'|' -f2)
    [ -z "$ROBLOX_USERNAME" ] && ROBLOX_USERNAME="N/A"
    [ -z "$ROBLOX_USER_ID" ]  && ROBLOX_USER_ID="N/A"

    echo "Account: $ROBLOX_USERNAME ($ROBLOX_USER_ID)"
    echo "Taking screenshot..."
    /system/bin/screencap -p "$SCREEN_PATH" >/dev/null 2>&1
    if [ ! -f "$SCREEN_PATH" ]; then
        echo "Screenshot failed."
        return
    fi

    PAYLOAD=$(cat <<EOF
{
    "embeds": [
        {
            "title": "Cloudphone Monitor",
            "fields": [
                {"name": "Time","value": "${DISCORD_TIME}","inline": false},
                {"name": "Roblox Account","value": "${ROBLOX_USERNAME}","inline": true},
                {"name": "Roblox User ID","value": "${ROBLOX_USER_ID}","inline": true},
                {"name": "CPU Usage","value": "${CPU_PERCENT}","inline": true},
                {"name": "RAM Usage","value": "${RAM_INFO}","inline": true},
                {"name": "Temperature","value": "${TEMPERATURE}","inline": true},
                {"name": "Battery","value": "${BATTERY}","inline": true},
                {"name": "Storage","value": "${STORAGE}","inline": true},
                {"name": "Uptime","value": "${UPTIME}","inline": true},
                {"name": "Instance","value": "${APP_STATUS}","inline": true},
                {"name": "Game State","value": "${GAME_STATE}","inline": true},
                {"name": "Roblox CPU","value": "${LAST_CPU_PCT}%","inline": true},
                {"name": "UDP Sockets","value": "${LAST_UDP}","inline": true}
            ],
            "image": {"url": "attachment://screen.png"}
        }
    ]
}
EOF
)

    echo "Sending report to Discord..."
    CURL_RESULT=$("$CURL" -sS -X POST "$WEBHOOK_URL" \
        -F "payload_json=${PAYLOAD}" \
        -F "file=@${SCREEN_PATH};filename=screen.png" 2>&1)
    CURL_EXIT=$?

    if [ "$CURL_EXIT" -eq 0 ]; then
        echo "Report sent."
    else
        echo "Discord upload failed: $CURL_RESULT"
    fi
}

# ============================================================
#  Watchdog
# ============================================================
watchdog() {
    PREVIOUS_INSTANCE_STATUS=$(get_instance_status)
    CACHED_ACCOUNT_TS=0
    PREVIOUS_ACCOUNT=$(get_roblox_account)
    PREVIOUS_USERNAME=$(echo "$PREVIOUS_ACCOUNT" | cut -d'|' -f1)
    PREVIOUS_USER_ID=$(echo "$PREVIOUS_ACCOUNT" | cut -d'|' -f2)

    echo "Watchdog started (poll ${CHECK_INTERVAL}s, heartbeat ${STATUS_EVERY}s)."
    echo "CPU in-game threshold: ${CPU_INGAME_THRESHOLD}%"
    echo "Out-of-game grace: ${OUT_OF_GAME_GRACE}s"
    echo "Initial instance: $PREVIOUS_INSTANCE_STATUS"

    while true; do
        ITER_START=$(/system/bin/date +%s)

        CURRENT_INSTANCE_STATUS=$(get_instance_status)

        if [ "$CURRENT_INSTANCE_STATUS" != "$PREVIOUS_INSTANCE_STATUS" ]; then
            if [ "$CURRENT_INSTANCE_STATUS" = "Closed" ]; then
                echo "Roblox: Running -> Closed"
                GAME_STATE="NOT_IN_GAME"
                NOT_IN_GAME_STREAK=0
                reset_cpu_sampling
                if [ "$RECOVERY_RUNNING" -eq 0 ]; then
                    launch_instance
                    if [ $? -eq 0 ]; then
                        wait_for_account
                        join_game
                        wait_for_game_start
                    fi
                fi
            else
                echo "Roblox: Closed -> Running"
                GAME_STATE="UNKNOWN"
                NOT_IN_GAME_STREAK=0
                reset_cpu_sampling
            fi
            PREVIOUS_INSTANCE_STATUS="$CURRENT_INSTANCE_STATUS"
        fi

        ACCOUNT_DATA=$(get_roblox_account)
        CURRENT_USERNAME=$(echo "$ACCOUNT_DATA" | cut -d'|' -f1)
        CURRENT_USER_ID=$(echo "$ACCOUNT_DATA" | cut -d'|' -f2)
        CURRENT_ACCOUNT="${CURRENT_USERNAME}|${CURRENT_USER_ID}"

        if [ "$CURRENT_ACCOUNT" != "$PREVIOUS_ACCOUNT" ]; then
            if [ "$CURRENT_USERNAME" = "N/A" ]; then
                echo "Roblox account unavailable."
            elif [ "$PREVIOUS_USERNAME" = "N/A" ]; then
                echo "Roblox account detected: $CURRENT_USERNAME"
                ACCOUNT_SEEN_THIS_SESSION=1
            else
                echo "Roblox account changed: $PREVIOUS_USERNAME -> $CURRENT_USERNAME"
                ACCOUNT_SEEN_THIS_SESSION=1
            fi
            PREVIOUS_ACCOUNT="$CURRENT_ACCOUNT"
            PREVIOUS_USERNAME="$CURRENT_USERNAME"
            PREVIOUS_USER_ID="$CURRENT_USER_ID"
        fi

        # ---- in-game detection ----
        CPU_NOW=0
        UDP_NOW=0
        if is_process_alive; then
            update_roblox_cpu_pct
            CPU_NOW="$ROBLOX_CPU_PCT"
            is_in_game_network && UDP_NOW=1
            LAST_UDP="$UDP_NOW"

            if is_in_game "$CPU_NOW" "$UDP_NOW"; then
                if [ "$GAME_STATE" != "IN_GAME" ]; then
                    echo "State -> IN_GAME (cpu=${CPU_NOW}% udp=${UDP_NOW})."
                fi
                GAME_STATE="IN_GAME"
                NOT_IN_GAME_STREAK=0
            else
                NOT_IN_GAME_STREAK=$((NOT_IN_GAME_STREAK + 1))

                if [ "$GAME_STATE" != "NOT_IN_GAME" ]; then
                    echo "State -> NOT_IN_GAME (cpu=${CPU_NOW}% udp=${UDP_NOW})."
                    GAME_STATE="NOT_IN_GAME"
                fi
            fi
        else
            GAME_STATE="NOT_IN_GAME"
            NOT_IN_GAME_STREAK=0
            reset_cpu_sampling
        fi

        # ---- rejoin decision (fresh time) ----
        NOW=$(/system/bin/date +%s)
        if [ "$NOT_IN_GAME_STREAK" -ge "$OUT_OF_GAME_GRACE" ]; then
            SINCE_JOIN=$((NOW - LAST_JOIN_TIME))
            if [ "$RECOVERY_RUNNING" -ne 0 ]; then
                echo "[block] recovery running."
            elif [ "$SINCE_JOIN" -lt "$REJOIN_COOLDOWN" ]; then
                echo "[block] cooldown: ${SINCE_JOIN}s / ${REJOIN_COOLDOWN}s since last join."
            else
                echo "Out of game for ${NOT_IN_GAME_STREAK}s — rejoining."
                send_join_intent
                GAME_STATE="JOINING"
                NOT_IN_GAME_STREAK=0
            fi
        fi

        # ---- heartbeat ----
        NOW=$(/system/bin/date +%s)
        if [ $((NOW - LAST_STATUS_TS)) -ge "$STATUS_EVERY" ]; then
            ITER_MS=$((NOW - ITER_START))
            echo "[status] state=${GAME_STATE} cpu=${CPU_NOW}% udp=${UDP_NOW} streak=${NOT_IN_GAME_STREAK}/${OUT_OF_GAME_GRACE} since_join=$((NOW - LAST_JOIN_TIME))s iter=${ITER_MS}s"
            LAST_STATUS_TS=$NOW
        fi

        sleep "$CHECK_INTERVAL"
    done
}

# ============================================================
#  Main
# ============================================================
echo "=============================="
echo "Cloudphone Monitor v2"
echo "=============================="
echo "Watchdog interval: ${CHECK_INTERVAL}s"
echo "Discord report interval: ${REPORT_INTERVAL}s"
echo "CPU in-game threshold: ${CPU_INGAME_THRESHOLD}%"
echo "Out-of-game grace: ${OUT_OF_GAME_GRACE}s"
echo "Auto game joining: Enabled"
echo "Auto recovery: Enabled"
echo "Auto login: $([ -f "$ACCOUNTS_FILE" ] && echo Enabled || echo Disabled)"
echo "=============================="

if ! is_process_alive; then
    start_and_join
else
    ACCOUNT_SEEN_THIS_SESSION=1
    CACHED_ACCOUNT_TS=0
    ACCOUNT_DATA=$(get_roblox_account)
    U=$(echo "$ACCOUNT_DATA" | cut -d'|' -f1)
    [ "$U" != "N/A" ] && echo "Existing account: $U"

    update_roblox_cpu_pct
    sleep 1
    update_roblox_cpu_pct
    CPU_NOW="$ROBLOX_CPU_PCT"
    UDP_NOW=0
    is_in_game_network && UDP_NOW=1

    if is_in_game "$CPU_NOW" "$UDP_NOW"; then
        echo "Already in game (cpu=${CPU_NOW}% udp=${UDP_NOW})."
        GAME_STATE="IN_GAME"
    else
        echo "Roblox running but not in-game — joining."
        join_game
        wait_for_game_start
    fi
fi

watchdog &
WATCHDOG_PID=$!

while true; do
    send_report
    echo "Next report in ${REPORT_INTERVAL}s."
    sleep "$REPORT_INTERVAL"
done