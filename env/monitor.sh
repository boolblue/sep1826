#!/system/bin/sh

WEBHOOK_URL="https://discord.com/api/webhooks/1478853919223451701/QBtFbDgqCs6xPrLLTjgCuzGyIT9uJpOD1LIubL5wIEF5Lm-On7wzyZ9UP2qMS2GmAnBK"

TARGET_PACKAGE="free.nokaA"
TARGET_ACTIVITY="com.roblox.client.startup.LauncherAliasMain"
TARGET_RUNNING_ACTIVITY="free.nokaA/com.roblox.client.ActivityNativeMain"

ROBLOX_STORAGE="/data/data/free.nokaA/files/appData/LocalStorage/appStorage.json"
ROBLOX_GAME_ID="1730877806"

SCREEN_PATH="/data/local/tmp/screen.png"

CURL="/data/data/com.termux/files/usr/bin/curl"

CHECK_INTERVAL=5
REPORT_INTERVAL=300

JOIN_WAIT=10
JOIN_TIMEOUT=45
RECOVERY_WAIT=15
GAME_RECHECK_INTERVAL=60

PREVIOUS_INSTANCE_STATUS=""
PREVIOUS_ACCOUNT=""

GAME_STATE="UNKNOWN"
LAST_JOIN_TIME=0
RECOVERY_RUNNING=0

get_cpu_usage() {
    CPU_LINE=$(top -n 1 -b 2>/dev/null | grep -i "cpu" | head -1)

    if [ -z "$CPU_LINE" ]; then
        echo "N/A"
        return
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
    TEMP=""

    for FILE in /sys/class/thermal/thermal_zone*/temp
    do
        if [ -f "$FILE" ]; then
            VALUE=$(cat "$FILE" 2>/dev/null)

            if [ -n "$VALUE" ] && [ "$VALUE" -gt 1000 ] 2>/dev/null; then
                TEMP=$((VALUE / 1000))
                break
            fi
        fi
    done

    if [ -n "$TEMP" ]; then
        echo "${TEMP}°C"
    else
        echo "N/A"
    fi
}

get_battery() {
    BATTERY_LEVEL=$(/system/bin/dumpsys battery 2>/dev/null | grep "level:" | head -1 | awk '{print $2}')

    if [ -n "$BATTERY_LEVEL" ]; then
        echo "${BATTERY_LEVEL}%"
    else
        echo "N/A"
    fi
}

get_uptime() {
    UPTIME_SECONDS=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)

    if [ -z "$UPTIME_SECONDS" ]; then
        echo "N/A"
        return
    fi

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

is_instance_running() {
    /system/bin/dumpsys activity activities 2>/dev/null | grep -q "$TARGET_RUNNING_ACTIVITY"
}

get_instance_status() {
    if is_instance_running; then
        echo "Running"
    else
        echo "Closed"
    fi
}

get_roblox_account() {
    if [ ! -f "$ROBLOX_STORAGE" ]; then
        echo "N/A|N/A"
        return
    fi

    RESULT=$(python3 - "$ROBLOX_STORAGE" 2>/dev/null <<'PY'
import sys
import json
import re

path = sys.argv[1]

try:
    with open(path, "r", encoding="utf-8") as f:
        data = f.read()
except:
    print("N/A|N/A")
    sys.exit()

accounts = []

patterns = [
    r'username\\":\\"([^"]*)\\".*?userIdentifier\\":\\"([^"]*)\\".*?userId\\":\\"([0-9]+)\\"',
    r'userIdentifier\\":\\"([^"]*)\\".*?displayName\\":\\"([^"]*)\\".*?userId\\":\\"([0-9]+)\\"'
]

for match in re.finditer(patterns[0], data):
    username = match.group(1)
    identifier = match.group(2)
    user_id = match.group(3)

    start = max(0, match.start() - 1000)
    end = min(len(data), match.end() + 1000)

    section = data[start:end]

    picker = re.search(r'showInAccountPicker\\":(true|false)', section)
    signed_out = re.search(r'signOutTimestamp\\":([0-9]+)', section)
    signed_in = re.search(r'signInTimestamp\\":([0-9]+)', section)

    show_picker = picker.group(1) == "true" if picker else False
    sign_out = int(signed_out.group(1)) if signed_out else None
    sign_in = int(signed_in.group(1)) if signed_in else 0

    if sign_out is not None:
        continue

    accounts.append({
        "username": username,
        "user_id": user_id,
        "picker": show_picker,
        "sign_in": sign_in
    })

if not accounts:
    for match in re.finditer(patterns[1], data):
        identifier = match.group(1)
        user_id = match.group(3)

        start = max(0, match.start() - 1000)
        end = min(len(data), match.end() + 1000)

        section = data[start:end]

        picker = re.search(r'showInAccountPicker\\":(true|false)', section)
        signed_out = re.search(r'signOutTimestamp\\":([0-9]+)', section)
        signed_in = re.search(r'signInTimestamp\\":([0-9]+)', section)

        show_picker = picker.group(1) == "true" if picker else False
        sign_out = int(signed_out.group(1)) if signed_out else None
        sign_in = int(signed_in.group(1)) if signed_in else 0

        if sign_out is not None:
            continue

        accounts.append({
            "username": identifier,
            "user_id": user_id,
            "picker": show_picker,
            "sign_in": sign_in
        })

if not accounts:
    print("N/A|N/A")
    sys.exit()

picker_accounts = [a for a in accounts if a["picker"]]

if picker_accounts:
    selected = picker_accounts[-1]
else:
    selected = sorted(accounts, key=lambda x: x["sign_in"], reverse=True)[0]

print(selected["username"] + "|" + selected["user_id"])
PY
)

    if [ -n "$RESULT" ] && echo "$RESULT" | grep -q '|'; then
        echo "$RESULT"
    else
        echo "N/A|N/A"
    fi
}

launch_instance() {
    echo "Launching $TARGET_PACKAGE..."

    /system/bin/am start -n "$TARGET_PACKAGE/$TARGET_ACTIVITY" >/dev/null 2>&1

    echo "Waiting for Roblox instance..."

    COUNT=0

    while [ "$COUNT" -lt 30 ]
    do
        if is_instance_running; then
            echo "Roblox instance started."
            return 0
        fi

        sleep 1
        COUNT=$((COUNT + 1))
    done

    echo "Roblox instance failed to start."
    return 1
}

wait_for_account() {
    echo "Waiting for Roblox account..."

    COUNT=0

    while [ "$COUNT" -lt 30 ]
    do
        ACCOUNT_DATA=$(get_roblox_account)

        ROBLOX_USERNAME=$(echo "$ACCOUNT_DATA" | cut -d'|' -f1)
        ROBLOX_USER_ID=$(echo "$ACCOUNT_DATA" | cut -d'|' -f2)

        if [ -n "$ROBLOX_USERNAME" ] && [ "$ROBLOX_USERNAME" != "N/A" ]; then
            echo "Roblox account detected: $ROBLOX_USERNAME ($ROBLOX_USER_ID)"
            return 0
        fi

        sleep 1
        COUNT=$((COUNT + 1))
    done

    echo "Roblox account was not detected."
    return 1
}

join_game() {
    if ! is_instance_running; then
        echo "Cannot join game because Roblox is not running."
        return 1
    fi

    echo "Waiting ${JOIN_WAIT} seconds before game join..."
    sleep "$JOIN_WAIT"

    if ! is_instance_running; then
        echo "Roblox stopped before game join."
        return 1
    fi

    echo "Joining Roblox game: $ROBLOX_GAME_ID"

    /system/bin/am start \
        -a android.intent.action.VIEW \
        -d "roblox://placeId=$ROBLOX_GAME_ID" \
        >/dev/null 2>&1

    LAST_JOIN_TIME=$(/system/bin/date +%s)
    GAME_STATE="JOINING"

    echo "Game join command sent."

    return 0
}

wait_for_game_start() {
    echo "Waiting for game to start..."

    COUNT=0

    while [ "$COUNT" -lt "$JOIN_TIMEOUT" ]
    do
        if ! is_instance_running; then
            echo "Roblox instance disappeared while joining."
            GAME_STATE="NOT_IN_GAME"
            return 1
        fi

        sleep 1
        COUNT=$((COUNT + 1))
    done

    GAME_STATE="IN_GAME"

    echo "Game join window completed."
    return 0
}

force_rejoin() {
    if [ "$RECOVERY_RUNNING" -eq 1 ]; then
        return
    fi

    RECOVERY_RUNNING=1

    echo "=============================="
    echo "ROBLOX GAME RECOVERY"
    echo "=============================="

    echo "Waiting ${RECOVERY_WAIT} seconds before recovery..."
    sleep "$RECOVERY_WAIT"

    if ! is_instance_running; then
        echo "Roblox instance is closed."
        echo "Launching Roblox..."

        launch_instance

        if [ $? -ne 0 ]; then
            echo "Failed to launch Roblox."
            RECOVERY_RUNNING=0
            return 1
        fi

        wait_for_account

        if [ $? -ne 0 ]; then
            echo "Account not detected after launch."
            RECOVERY_RUNNING=0
            return 1
        fi

        join_game
        wait_for_game_start

        RECOVERY_RUNNING=0
        return 0
    fi

    echo "Roblox instance is still running."
    echo "Sending game join command again..."

    /system/bin/am start \
        -a android.intent.action.VIEW \
        -d "roblox://placeId=$ROBLOX_GAME_ID" \
        >/dev/null 2>&1

    LAST_JOIN_TIME=$(/system/bin/date +%s)
    GAME_STATE="JOINING"

    sleep "$JOIN_TIMEOUT"

    if is_instance_running; then
        GAME_STATE="IN_GAME"
        echo "Game rejoin command completed."
        RECOVERY_RUNNING=0
        return 0
    fi

    echo "Game rejoin did not keep Roblox running."
    echo "Restarting Roblox instance..."

    /system/bin/am force-stop "$TARGET_PACKAGE" >/dev/null 2>&1

    sleep 3

    launch_instance

    if [ $? -ne 0 ]; then
        echo "Roblox relaunch failed."
        RECOVERY_RUNNING=0
        return 1
    fi

    wait_for_account

    if [ $? -ne 0 ]; then
        echo "Account detection failed after relaunch."
        RECOVERY_RUNNING=0
        return 1
    fi

    join_game
    wait_for_game_start

    RECOVERY_RUNNING=0

    return 0
}

check_game_state() {
    if ! is_instance_running; then
        GAME_STATE="NOT_IN_GAME"
        return 1
    fi

    if [ "$GAME_STATE" = "UNKNOWN" ]; then
        return 0
    fi

    if [ "$GAME_STATE" = "JOINING" ]; then
        return 0
    fi

    if [ "$GAME_STATE" = "IN_GAME" ]; then
        return 0
    fi

    return 0
}

start_and_join() {
    if ! is_instance_running; then
        launch_instance

        if [ $? -ne 0 ]; then
            return 1
        fi
    fi

    wait_for_account

    if [ $? -ne 0 ]; then
        return 1
    fi

    join_game

    if [ $? -ne 0 ]; then
        return 1
    fi

    wait_for_game_start

    return 0
}

send_report() {
    echo "Collecting report data..."

    UNIX_TIME=$(/system/bin/date +%s)
    DISCORD_TIME="<t:${UNIX_TIME}:F>"

    CPU_PERCENT=$(get_cpu_usage)

    RAM_TOTAL=$(/system/bin/free -m 2>/dev/null | awk '/Mem:/ {print $2}')
    RAM_USED=$(/system/bin/free -m 2>/dev/null | awk '/Mem:/ {print $3}')

    if [ -n "$RAM_TOTAL" ] && [ -n "$RAM_USED" ]; then
        RAM_PERCENT=$((RAM_USED * 100 / RAM_TOTAL))
        RAM_INFO="${RAM_USED} MB / ${RAM_TOTAL} MB (${RAM_PERCENT}%)"
    else
        RAM_INFO="N/A"
    fi

    TEMPERATURE=$(get_cpu_temperature)
    BATTERY=$(get_battery)
    STORAGE=$(get_storage)
    UPTIME=$(get_uptime)

    APP_STATUS=$(get_instance_status)

    ACCOUNT_DATA=$(get_roblox_account)

    ROBLOX_USERNAME=$(echo "$ACCOUNT_DATA" | cut -d'|' -f1)
    ROBLOX_USER_ID=$(echo "$ACCOUNT_DATA" | cut -d'|' -f2)

    if [ -z "$ROBLOX_USERNAME" ]; then
        ROBLOX_USERNAME="N/A"
    fi

    if [ -z "$ROBLOX_USER_ID" ]; then
        ROBLOX_USER_ID="N/A"
    fi

    echo "Roblox Account: ${ROBLOX_USERNAME}"
    echo "Roblox User ID: ${ROBLOX_USER_ID}"
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
                {"name": "Instance","value": "${APP_STATUS}","inline": true}
            ],
            "image": {"url": "attachment://screen.png"}
        }
    ]
}
EOF
)

    echo "Sending report to Discord..."

    CURL_RESULT=$("$CURL" -sS \
        -X POST \
        "$WEBHOOK_URL" \
        -F "payload_json=${PAYLOAD}" \
        -F "file=@${SCREEN_PATH};filename=screen.png" \
        2>&1)

    CURL_EXIT=$?

    if [ "$CURL_EXIT" -eq 0 ]; then
        echo "Discord response: ${CURL_RESULT}"
        echo "Report sent successfully."
    else
        echo "Discord upload failed."
        echo "curl error: ${CURL_RESULT}"
    fi
}

watchdog() {
    PREVIOUS_INSTANCE_STATUS=$(get_instance_status)
    PREVIOUS_ACCOUNT=$(get_roblox_account)

    PREVIOUS_USERNAME=$(echo "$PREVIOUS_ACCOUNT" | cut -d'|' -f1)
    PREVIOUS_USER_ID=$(echo "$PREVIOUS_ACCOUNT" | cut -d'|' -f2)

    echo "Watchdog started."
    echo "Initial instance status: $PREVIOUS_INSTANCE_STATUS"

    if [ "$PREVIOUS_USERNAME" != "N/A" ]; then
        echo "Initial Roblox account: $PREVIOUS_USERNAME ($PREVIOUS_USER_ID)"
    else
        echo "Initial Roblox account: N/A"
    fi

    while true
    do
        CURRENT_INSTANCE_STATUS=$(get_instance_status)

        if [ "$CURRENT_INSTANCE_STATUS" != "$PREVIOUS_INSTANCE_STATUS" ]; then

            if [ "$CURRENT_INSTANCE_STATUS" = "Closed" ]; then

                echo "Roblox instance changed: Running -> Closed"

                GAME_STATE="NOT_IN_GAME"

                if [ "$RECOVERY_RUNNING" -eq 0 ]; then
                    echo "Launching Roblox instance..."

                    launch_instance

                    if [ $? -eq 0 ]; then
                        wait_for_account
                        join_game
                        wait_for_game_start
                    fi
                fi

            else

                echo "Roblox instance changed: Closed -> Running"

                GAME_STATE="UNKNOWN"

            fi

            PREVIOUS_INSTANCE_STATUS="$CURRENT_INSTANCE_STATUS"
        fi

        ACCOUNT_DATA=$(get_roblox_account)

        CURRENT_USERNAME=$(echo "$ACCOUNT_DATA" | cut -d'|' -f1)
        CURRENT_USER_ID=$(echo "$ACCOUNT_DATA" | cut -d'|' -f2)

        CURRENT_ACCOUNT="${CURRENT_USERNAME}|${CURRENT_USER_ID}"

        if [ "$CURRENT_ACCOUNT" != "$PREVIOUS_ACCOUNT" ]; then

            if [ "$CURRENT_USERNAME" = "N/A" ]; then

                echo "Roblox account data became unavailable."

            elif [ "$PREVIOUS_USERNAME" = "N/A" ]; then

                echo "Roblox account detected: $CURRENT_USERNAME ($CURRENT_USER_ID)"

            else

                echo "Roblox account changed:"
                echo "Previous: $PREVIOUS_USERNAME ($PREVIOUS_USER_ID)"
                echo "Current:  $CURRENT_USERNAME ($CURRENT_USER_ID)"

            fi

            PREVIOUS_ACCOUNT="$CURRENT_ACCOUNT"
            PREVIOUS_USERNAME="$CURRENT_USERNAME"
            PREVIOUS_USER_ID="$CURRENT_USER_ID"
        fi

        if is_instance_running; then

            CURRENT_TIME=$(/system/bin/date +%s)

            if [ "$GAME_STATE" = "IN_GAME" ]; then

                ELAPSED=$((CURRENT_TIME - LAST_JOIN_TIME))

                if [ "$ELAPSED" -ge "$GAME_RECHECK_INTERVAL" ]; then

                    echo "Game state recheck."

                    /system/bin/am start \
                        -a android.intent.action.VIEW \
                        -d "roblox://placeId=$ROBLOX_GAME_ID" \
                        >/dev/null 2>&1

                    LAST_JOIN_TIME=$CURRENT_TIME

                    echo "Game join verification command sent."

                fi

            elif [ "$GAME_STATE" = "UNKNOWN" ]; then

                echo "Game state unknown."
                echo "Sending initial game join..."

                join_game

            elif [ "$GAME_STATE" = "NOT_IN_GAME" ]; then

                if [ "$RECOVERY_RUNNING" -eq 0 ]; then
                    echo "Roblox is running but game state is not active."
                    force_rejoin
                fi

            fi

        else

            GAME_STATE="NOT_IN_GAME"

        fi

        sleep "$CHECK_INTERVAL"
    done
}

echo "=============================="
echo "Cloudphone Monitor"
echo "=============================="
echo "Watchdog interval: ${CHECK_INTERVAL}s"
echo "Discord report interval: ${REPORT_INTERVAL}s"
echo "Automatic game joining: Enabled"
echo "Automatic recovery: Enabled"
echo "OCR: Disabled"
echo "Display resizing: Disabled"
echo "=============================="

if ! is_instance_running; then
    start_and_join
else
    ACCOUNT_DATA=$(get_roblox_account)

    if [ -n "$ACCOUNT_DATA" ]; then
        ROBLOX_USERNAME=$(echo "$ACCOUNT_DATA" | cut -d'|' -f1)

        if [ "$ROBLOX_USERNAME" != "N/A" ]; then
            echo "Existing Roblox account detected: $ROBLOX_USERNAME"
        fi
    fi

    echo "Roblox instance already running."
    echo "Sending game join command..."

    join_game
    wait_for_game_start
fi

watchdog &
WATCHDOG_PID=$!

while true
do
    send_report

    echo "Next Discord report in ${REPORT_INTERVAL} seconds."

    sleep "$REPORT_INTERVAL"
done
