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

DISCONNECT_CONFIRM_COUNT=2
REJOIN_WAIT=15
REJOIN_TIMEOUT=45

PREVIOUS_INSTANCE_STATUS=""
PREVIOUS_ACCOUNT=""

get_cpu_usage() {
    CPU_LINE=$(top -n 1 -b 2>/dev/null | grep -i "cpu" | head -1)

    if [ -n "$CPU_LINE" ]; then
        echo "$CPU_LINE"
    else
        echo "N/A"
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

    ACCOUNT_DATA=$(grep -o 'username\\":\\"[^"]*\\",\\"userIdentifier\\":\\"[^"]*\\",\\"displayName\\":\\"[^"]*\\",\\"showInAccountPicker\\":[^,]*,\\"signInTimestamp\\":[0-9]*,\\"userId\\":\\"[0-9]*\\"' "$ROBLOX_STORAGE" 2>/dev/null)

    if [ -z "$ACCOUNT_DATA" ]; then
        echo "N/A|N/A"
        return
    fi

    RESULT=$(echo "$ACCOUNT_DATA" | while read -r ACCOUNT
    do
        USERNAME=$(echo "$ACCOUNT" | sed 's/.*username\\":\\"//;s/\\".*//')
        USER_ID=$(echo "$ACCOUNT" | sed 's/.*userId\\":\\"//;s/\\".*//')
        TIMESTAMP=$(echo "$ACCOUNT" | sed 's/.*signInTimestamp\\"://;s/,.*//')

        if [ -n "$USERNAME" ] && [ -n "$USER_ID" ] && [ -n "$TIMESTAMP" ]; then
            echo "$TIMESTAMP|$USERNAME|$USER_ID"
        fi
    done | sort -n | tail -1 | cut -d'|' -f2-3)

    if [ -n "$RESULT" ]; then
        echo "$RESULT"
    else
        echo "N/A|N/A"
    fi
}

launch_instance() {
    echo "Launching $TARGET_PACKAGE..."

    /system/bin/am start \
        -n "$TARGET_PACKAGE/$TARGET_ACTIVITY" \
        >/dev/null 2>&1

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

    echo "Waiting 10 seconds before game join..."
    sleep 10

    if ! is_instance_running; then
        echo "Roblox stopped before game join."
        return 1
    fi

    echo "Joining Roblox game: $ROBLOX_GAME_ID"

    /system/bin/am start \
        -a android.intent.action.VIEW \
        -d "roblox://placeId=$ROBLOX_GAME_ID" \
        >/dev/null 2>&1

    echo "Game join command sent."

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

    return $?
}

get_ui_dump() {
    UI_FILE="/data/local/tmp/roblox_ui.xml"

    /system/bin/uiautomator dump "$UI_FILE" >/dev/null 2>&1

    if [ -f "$UI_FILE" ]; then
        cat "$UI_FILE"
        rm -f "$UI_FILE"
    fi
}

is_disconnect_screen() {
    if ! is_instance_running; then
        return 0
    fi

    UI_DATA=$(get_ui_dump)

    if [ -z "$UI_DATA" ]; then
        return 1
    fi

    echo "$UI_DATA" | grep -i -q -E \
        'disconnected|connection failed|connection error|error code: ?(277|279|266|280)|error 277|error 279|error 266|error 280|lost connection|internet connection'
}

wait_for_disconnect_confirmation() {
    COUNT=0

    while [ "$COUNT" -lt "$DISCONNECT_CONFIRM_COUNT" ]
    do
        if is_disconnect_screen; then
            COUNT=$((COUNT + 1))

            if [ "$COUNT" -lt "$DISCONNECT_CONFIRM_COUNT" ]; then
                sleep "$CHECK_INTERVAL"
            fi
        else
            return 1
        fi
    done

    return 0
}

rejoin_game() {
    echo "Attempting Roblox game rejoin..."

    /system/bin/am start \
        -a android.intent.action.VIEW \
        -d "roblox://placeId=$ROBLOX_GAME_ID" \
        >/dev/null 2>&1

    COUNT=0

    while [ "$COUNT" -lt "$REJOIN_TIMEOUT" ]
    do
        sleep 1

        if ! is_disconnect_screen; then
            echo "Roblox rejoin appears successful."
            return 0
        fi

        COUNT=$((COUNT + 1))
    done

    echo "Rejoin did not recover Roblox."
    return 1
}

recover_roblox() {
    echo "=============================="
    echo "ROBLOX DISCONNECT DETECTED"
    echo "=============================="

    echo "Waiting ${REJOIN_WAIT} seconds before recovery..."
    sleep "$REJOIN_WAIT"

    if ! is_instance_running; then
        echo "Instance disappeared."
        echo "Launching instance again..."

        launch_instance

        if [ $? -ne 0 ]; then
            echo "Instance relaunch failed."
            return 1
        fi

        wait_for_account
        join_game

        return $?
    fi

    echo "Attempting direct game rejoin..."

    rejoin_game

    if [ $? -eq 0 ]; then
        return 0
    fi

    echo "Direct rejoin failed."
    echo "Relaunching Roblox instance..."

    /system/bin/am force-stop "$TARGET_PACKAGE" >/dev/null 2>&1

    sleep 3

    launch_instance

    if [ $? -ne 0 ]; then
        echo "Instance relaunch failed."
        return 1
    fi

    wait_for_account

    if [ $? -ne 0 ]; then
        return 1
    fi

    join_game

    return $?
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
                {
                    "name": "Time",
                    "value": "${DISCORD_TIME}",
                    "inline": false
                },
                {
                    "name": "Roblox Account",
                    "value": "${ROBLOX_USERNAME}",
                    "inline": true
                },
                {
                    "name": "Roblox User ID",
                    "value": "${ROBLOX_USER_ID}",
                    "inline": true
                },
                {
                    "name": "CPU Usage",
                    "value": "${CPU_PERCENT}",
                    "inline": true
                },
                {
                    "name": "RAM Usage",
                    "value": "${RAM_INFO}",
                    "inline": true
                },
                {
                    "name": "Temperature",
                    "value": "${TEMPERATURE}",
                    "inline": true
                },
                {
                    "name": "Battery",
                    "value": "${BATTERY}",
                    "inline": true
                },
                {
                    "name": "Storage",
                    "value": "${STORAGE}",
                    "inline": true
                },
                {
                    "name": "Uptime",
                    "value": "${UPTIME}",
                    "inline": true
                },
                {
                    "name": "Instance",
                    "value": "${APP_STATUS}",
                    "inline": true
                }
            ],
            "image": {
                "url": "attachment://screen.png"
            }
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
        echo "Discord response: ${CURL_RESULT}"
        echo "Report sent successfully."
    else
        echo "Discord upload failed."
        echo "curl error: ${CURL_RESULT}"
    fi
}

watchdog() {
    DISCONNECT_COUNT=0

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
                echo "Launching Roblox instance..."

                launch_instance

                if [ $? -eq 0 ]; then
                    wait_for_account
                    join_game
                fi
            else
                echo "Roblox instance changed: Closed -> Running"
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

            if is_disconnect_screen; then
                DISCONNECT_COUNT=$((DISCONNECT_COUNT + 1))

                if [ "$DISCONNECT_COUNT" -ge "$DISCONNECT_CONFIRM_COUNT" ]; then
                    recover_roblox
                    DISCONNECT_COUNT=0

                    PREVIOUS_INSTANCE_STATUS=$(get_instance_status)
                    PREVIOUS_ACCOUNT=$(get_roblox_account)
                    PREVIOUS_USERNAME=$(echo "$PREVIOUS_ACCOUNT" | cut -d'|' -f1)
                    PREVIOUS_USER_ID=$(echo "$PREVIOUS_ACCOUNT" | cut -d'|' -f2)
                fi
            else
                DISCONNECT_COUNT=0
            fi
        else
            DISCONNECT_COUNT=0
        fi

        sleep "$CHECK_INTERVAL"
    done
}

echo "=============================="
echo "Cloudphone Monitor"
echo "=============================="
echo "Watchdog interval: ${CHECK_INTERVAL}s"
echo "Discord report interval: ${REPORT_INTERVAL}s"
echo "Disconnect detection: Enabled"
echo "Disconnect confirmations: ${DISCONNECT_CONFIRM_COUNT}"
echo "OCR: Disabled"
echo "Display resizing: Disabled"
echo "=============================="

if ! is_instance_running; then
    start_and_join
fi

watchdog &
WATCHDOG_PID=$!

while true
do
    send_report

    echo "Next Discord report in ${REPORT_INTERVAL} seconds."

    sleep "$REPORT_INTERVAL"
done