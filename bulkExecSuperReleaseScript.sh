#!/bin/bash

SEARCH_DIR="$1"
SUCCESS_LIST=()
FAIL_LIST=()
COUNTER=0

while IFS= read -r -d '' VIDEO_FILE; do
    if [[ "$(basename "$VIDEO_FILE")" =~ [Tt][Rr][Aa][Ii][Ll][Ee][Rr] ]]; then
        continue
    fi

    ((COUNTER++))

    printf 'DEBUG VIDEO_FILE: <%q>\n' "$VIDEO_FILE"
    printf 'DEBUG basename: <%q>\n' "$(basename "$VIDEO_FILE")"

    echo "Verarbeite: $VIDEO_FILE"
    echo "/root/createSuperRelease.sh $VIDEO_FILE"

    /root/createSuperRelease.sh "$VIDEO_FILE"
    EXIT_CODE=$?

    if [[ $EXIT_CODE -eq 1 ]]; then
        echo "Failed Processing for: $VIDEO_FILE"
        FAIL_LIST+=("$VIDEO_FILE")
    else
        echo "Success! $VIDEO_FILE"
        SUCCESS_LIST+=("$VIDEO_FILE")
    fi

    if [[ $COUNTER -ge 30 ]]; then
        break
    fi
done < <(
    find "$SEARCH_DIR" -type f \
        \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.wmv" -o -iname "*.webm" -o -iname "*.m4v" \) \
        -print0 |
    sort -z
)


echo "FILES SUCCEEDED:"
printf '%s\n' "${SUCCESS_LIST[@]}"

echo ""
echo "FILES FAILED:"
printf '%s\n' "${FAIL_LIST[@]}"

echo "Script Execution Completed."
