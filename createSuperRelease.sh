#!/bin/bash
#exec > /root/superReleaseScript.log 2>&1
API_KEY="secret" # your sonarr API key
SONARR_URL="http://127.0.0.1:8989" # your local sonarr URL
SONARR_DB_PATH="/opt/sonarr/config/sonarr.db" # absolute host path to sonarr database

FILE_PATH="/hdd/media/anime/OnePiece/Season 1/episode1.mkv" # absolute host path to media file
FILE_PATH="$1"
WORKING_DIR="/temp/transcode_cache/" # working directory for merging audio streams and creating new end file
MERGE_AUDIO_SCRIPT_PATH="/root/mergeAudio.py" # absolute host path to merge audio script
PERMS_GROUP="koray:media" # file permission groups for resulting file

# sqlite3 -noheader -batch $SONARR_DB_PATH \ # uncomment this section and execute it to retrieve the quality profile names and IDs
#   "SELECT Id,Name FROM QualityProfiles"
# exit 0
QualityProfileId_ger=17 # one profile is needed for first language and another for second language
QualityProfileId_eng=16

ENGLISH_ID=1 # internal sonarr Language IDs (probably the same for everyone)
GERMAN_ID=4




### Retrieve file ###
SHORT_PATH=$(echo "$FILE_PATH" | sed -E 's|^.*/(Season [0-9]+/.*)|\1|')
REL_PATH=$(printf "%s" "$SHORT_PATH" | sed "s/'/''/g")
echo "Handling file: $REL_PATH"

### Retrieve SERIES ID ###
SERIES_ID=$(sqlite3 -noheader -batch $SONARR_DB_PATH \
  "SELECT SeriesId FROM EpisodeFiles WHERE RelativePath = '$REL_PATH'")
echo "SERIES ID: $SERIES_ID"

### Check whether it's a multi-episode file and therefore has several episodes assigned to a single file ###
COUNT_EPISODES=$(sqlite3 -noheader -batch $SONARR_DB_PATH \
  "SELECT COUNT(Id) FROM EpisodeFiles WHERE RelativePath = '$REL_PATH'")
if [[ "$COUNT_EPISODES" > 1 ]]; then
    echo "Multiple Episodes belong to a Single Episode File. Exiting."
    exit 1
fi



### Retrieve unique episode file ID and Release Group ###
IFS='|' read -r EPISODE_FILE_ID RELEASE_GROUP < <(
    sqlite3 -noheader -batch $SONARR_DB_PATH \
    "SELECT Id,ReleaseGroup FROM EpisodeFiles WHERE RelativePath = '$REL_PATH'"
)
#EPISODE_FILE_ID=$(sqlite3 -noheader -batch $SONARR_DB_PATH \
#  "SELECT Id FROM EpisodeFiles WHERE RelativePath = '$REL_PATH'")
echo "EPISODE FILE ID: $EPISODE_FILE_ID AND Release Group: $RELEASE_GROUP"

### Retrieve Episode Information such as ID, season number and episode number ###
IFS='|' read -r EPISODE_ID SEASON_NUMBER EPISODE_NUMBER < <(
    sqlite3 -noheader -batch $SONARR_DB_PATH \
    "SELECT Id, SeasonNumber, EpisodeNumber FROM Episodes WHERE EpisodeFileId = $EPISODE_FILE_ID"
)
echo "Found Episode Id: $EPISODE_ID AND SEASON $SEASON_NUMBER AND EPISODE $EPISODE_NUMBER"

### check whether file has english audio according to sonarr's ffprobe scan ###
HAS_ENGLISH=$(sqlite3 -noheader -batch $SONARR_DB_PATH "
SELECT EXISTS (
  SELECT 1
  FROM EpisodeFiles,
       json_each(EpisodeFiles.Languages)
  WHERE EpisodeFiles.SeriesId = $SERIES_ID
    AND EpisodeFiles.Id = $EPISODE_FILE_ID
    AND json_each.value = $ENGLISH_ID
);
")

### check whether file has german audio according to sonarr's ffprobe scan ###
HAS_GERMAN=$(sqlite3 -noheader -batch $SONARR_DB_PATH "
SELECT EXISTS (
  SELECT 1
  FROM EpisodeFiles,
       json_each(EpisodeFiles.Languages)
  WHERE EpisodeFiles.SeriesId = $SERIES_ID
    AND EpisodeFiles.Id = $EPISODE_FILE_ID
    AND json_each.value = $GERMAN_ID
);
")

### only process files that either have german or english audio stream ###
if [[ "$HAS_ENGLISH" -eq 1 && "$HAS_GERMAN" -eq 1 ]]; then
    echo "German and English included. Exiting"
    exit 0
elif [[ "$HAS_ENGLISH" != 1 && "$HAS_GERMAN" != 1 ]]; then
    echo "German and English missing. Exiting"
    exit 0
elif [[ "$HAS_GERMAN" -eq 1 ]]; then
    echo "English missing"
    MISSING_LANG="$QualityProfileId_eng"
    MISSING_LANG_NAME="eng"
elif [[ "$HAS_ENGLISH" -eq 1 ]]; then
    echo "German missing"
    MISSING_LANG="$QualityProfileId_ger"
    MISSING_LANG_NAME="ger"
fi


### Retrieve current Quality Profile ID ###
QualityProfileId_original=$(sqlite3 -noheader -batch $SONARR_DB_PATH \
  "SELECT QualityProfileId FROM Series WHERE Id = $SERIES_ID")

### Retrieve new Quality Profile Name ###
QualityProfileName=$(sqlite3 -noheader -batch $SONARR_DB_PATH \
  "SELECT Name FROM QualityProfiles WHERE Id = $MISSING_LANG")

### Change Quality Profile to missing language ###
echo "Temporarily changing Series QualityProfile to $MISSING_LANG $QualityProfileName"
sqlite3 -noheader -batch $SONARR_DB_PATH \
  "UPDATE Series SET QualityProfileId = $MISSING_LANG WHERE Id = $SERIES_ID"

sleep 1

### Use sonarr API to start searching for new release that has the missing language ###
echo "Searching for new release matching missing language"
RESPONSE=$(curl -s -X POST "$SONARR_URL/api/v3/command" \
  -H "X-Api-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
        \"name\":\"EpisodeSearch\",
        \"episodeIds\":[$EPISODE_ID]
      }")
COMMAND_ID=$(jq -r '.id' <<< "$RESPONSE")

sleep 1

### Retrieve Name of original Quality Profile ###
echo "Retrieving original QualityProfileName"
QualityProfileName=$(sqlite3 -noheader -batch $SONARR_DB_PATH \
  "SELECT Name FROM QualityProfiles WHERE Id = $QualityProfileId_original")

### Change Series Quality Profile back to original Quality Profile while sonarr keeps searching for new release ###
echo "Changing Series QualityProfile back to $QualityProfileName"
sqlite3 -noheader -batch $SONARR_DB_PATH \
  "UPDATE Series SET QualityProfileId = $QualityProfileId_original WHERE Id = $SERIES_ID"


### Use sonarr API to periodically check whether episode search has found a new release yet ###
while true; do
    RESPONSE=$(curl -s \
      -H "X-Api-Key: $API_KEY" \
      "$SONARR_URL/api/v3/command/$COMMAND_ID")
    echo "$RESPONSE"

    STATUS=$(jq -r '.status' <<< "$RESPONSE")
    RESULT=$(jq -r '.result' <<< "$RESPONSE")
    REPORTS=$(jq -r '.message | capture("(?<count>[0-9]+) reports downloaded") | .count' <<< "$RESPONSE")

    echo "Sonarr Command Status: $STATUS"
    echo "Reports downloaded: $REPORTS"

    if [[ "$STATUS" == "completed" ]]; then
        break
    fi

    echo "Retrying in 5 seconds"
    sleep 5
done

### Check whether a release was found. Exit script if not ###
if [[ "$RESULT" != "successful" || "$REPORTS" -eq 0 ]]; then
    echo "No Release found. Exiting"
    exit 1
else
    echo "Release found. Continuing..."
fi


### Use sonarr API to periodically check the queue for when the new release has been downloaded ###
while true; do
    RESPONSE=$(curl -s \
      -H "X-Api-Key: $API_KEY" \
      "$SONARR_URL/api/v3/queue?page=1&pageSize=100")

    echo "$RESPONSE" | jq

    QUEUE_ENTRY=$(jq -c --argjson id "$EPISODE_ID" \
        '.records[] | select(.episodeId == $id)' <<< "$RESPONSE")

    if [[ -z "$QUEUE_ENTRY" ]]; then
        echo "No Queue Entry for $EPISODE_ID found yet. Retrying in 10 seconds."
        sleep 10
        continue
    fi

    STATUS=$(jq -r '.status' <<< "$QUEUE_ENTRY")
    TIMELEFT=$(jq -r '.timeleft // empty' <<< "$QUEUE_ENTRY")

    echo "Sonarr Status: $STATUS"
    echo "Timeleft: $TIMELEFT"

    if [[ "$STATUS" == "completed" ]]; then
        echo "Download completed."
        OUTPUT_PATH=$(jq -r '.outputPath // empty' <<< "$QUEUE_ENTRY")
        QUEUE_ID=$(jq -r '.id // empty' <<< "$QUEUE_ENTRY")
        break
    fi

    if [[ "$TIMELEFT" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        IFS=: read -r HOURS MINUTES SECONDS <<< "$TIMELEFT"
        SLEEP_TIME=$((10#$HOURS * 3600 + 10#$MINUTES * 60 + 10#$SECONDS))
    else
        SLEEP_TIME=30
    fi

    if (( SLEEP_TIME > 30 )); then
        SLEEP_TIME=30
    elif (( SLEEP_TIME < 10 )); then
        SLEEP_TIME=10
    fi

    echo "Next check in $SLEEP_TIME seconds."
    sleep "$SLEEP_TIME"
done


echo "Sonarr download is done. Downloaded file is $OUTPUT_PATH"

### Find video file in newly created download file path ###
AUDIO_SOURCE="$(find "$OUTPUT_PATH" -type f \( \
    -iname "*.mkv" -o \
    -iname "*.mp4" -o \
    -iname "*.avi" -o \
    -iname "*.mov" -o \
    -iname "*.webm" -o \
    -iname "*.m4v" -o \
    -iname "*.ts" \
    \) -print -quit)"

if [[ -z "$AUDIO_SOURCE" ]]; then
    echo "No video file found."
    exit 1
fi

### Checking whether new file actually has wanted language ###
echo "Checking downloaded file for whether it has wanted audio language"
if [[ "$MISSING_LANG_NAME" == "ger" ]]; then
    AUDIO_LANG="de|deu|ger"
elif [[ "$MISSING_LANG_NAME" == "eng" ]]; then
    AUDIO_LANG="en|eng"
else
    echo "Ungültige Sprache: $LANG"
    exit 1
fi

if ffprobe -v error \
    -select_streams a \
    -show_entries stream_tags=language \
    -of csv=p=0 \
    "$AUDIO_SOURCE" | grep -Eqi "^$AUDIO_LANG$"; then
    echo "File has wanted audio language"
else ### If File doesn\'t have the wanted audio language, check for the other language. Although we don\'t want it, we can blacklist this release if it doesn\'t have any viable language (here: neither german or english) ###
    if [[ "$AUDIO_LANG" == "en" ]]; then
      AUDIO_LANG="de|deu|ger"
    else
      AUDIO_LANG="en|eng"
    fi
    echo "File doesn't have wanted audio language. Exiting."
    if ! ffprobe -v error \
        -select_streams a \
        -show_entries stream_tags=language \
        -of csv=p=0 \
        "$AUDIO_SOURCE" | grep -Eqi "^$AUDIO_LANG$"; then
        echo "File also doesn't have other viable language. Blacklisting release..."

        HISTORY=$(curl -s \
          -H "X-Api-Key: $API_KEY" \
          "$SONARR_URL/api/v3/history?downloadid=$DOWNLOAD_ID&pageSize=50")

        # retrieve history ID
        echo "Retrieving History ID of Download"
        echo "$HISTORY"
        FAILED_HISTORY_ID=$(echo "$HISTORY" | jq -r '
          .records
          | map(select(.eventType == "grabbed"))
          | sort_by(.date)
          | reverse
          | .[0].id
        ')

        # mark release as failed
        echo "Marking release as failed: $FAILED_HISTORY_ID"
        curl -s -X POST \
          "$SONARR_URL/api/v3/history/failed/$FAILED_HISTORY_ID" \
          -H "X-Api-Key: $API_KEY" \
          > /dev/null

        echo "Removing downloaded file"
        rm -r "$OUTPUT_PATH"

        echo "Cleaning up Queue Entry"
        curl -s -X DELETE \
          -H "X-Api-Key: $API_KEY" \
          "$SONARR_URL/api/v3/queue/$QUEUE_ID"
    fi
    echo "Re-Running Script"
    sleep 5
    exec "$0" "$@"
    exit 1
fi

echo "Moving file to working directory $WORKING_DIR"
### Move Found Video File to Working Directory ###
extension="${AUDIO_SOURCE##*.}"
AUDIO_FILE_PATH="${WORKING_DIR}file_audio.${extension}"

mv -- "$AUDIO_SOURCE" "$AUDIO_FILE_PATH"

### Copy Original File to Working Directory ###
echo "Copying original file to working directory"
cp "$FILE_PATH" "$WORKING_DIR"

### Retrieve absolute file path in working directory ###
FILE_PATH_BASE="$(basename "$FILE_PATH")"
BASE_FILE_PATH="${WORKING_DIR}$FILE_PATH_BASE"




### Delete Sonarr Queue Entry using sonarr API since file doesn't exist in download directory anymore ###
echo "Cleaning up Queue Entry"
curl -s -X DELETE \
  -H "X-Api-Key: $API_KEY" \
  "$SONARR_URL/api/v3/queue/$QUEUE_ID"

### Start executing python script to calculate audio stream offset and synchronize audio streams of original file and new file ###
echo "Executing command: $MERGE_AUDIO_SCRIPT_PATH $BASE_FILE_PATH $AUDIO_FILE_PATH $MISSING_LANG_NAME /temp/transcode_cache/test.mkv"
"$MERGE_AUDIO_SCRIPT_PATH" "$BASE_FILE_PATH" "$AUDIO_FILE_PATH" "$MISSING_LANG_NAME" "/temp/transcode_cache/test.mkv"

### Delete working files to only keep file with merged audio streams ###
echo "Audios have been merged. Deleting working files..."
rm "$BASE_FILE_PATH"
rm "$AUDIO_FILE_PATH"

echo "Renaming resulting file to original file name"
mv "/temp/transcode_cache/test.mkv" "$BASE_FILE_PATH"

echo "Adjusting permissions of resulting file so Sonarr can access it"
chown $PERMS_GROUP "$BASE_FILE_PATH"

echo "Deleting original file in order to replace it"
curl -X DELETE \
  "$SONARR_URL/api/v3/episodefile/$EPISODE_FILE_ID" \
  -H "X-Api-Key: $API_KEY"
#rm "$FILE_PATH"

sleep 1

echo "Calling Sonarr API to import resulting file"
RESPONSE=$(curl -X POST \
  -H "X-Api-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  "$SONARR_URL/api/v3/command" \
  -d '{
    "name": "DownloadedEpisodesScan",
    "path": "'"$BASE_FILE_PATH"'"
  }')
COMMAND_ID=$(jq -r '.id' <<< "$RESPONSE")

while true; do
    RESPONSE=$(curl -s \
      -H "X-Api-Key: $API_KEY" \
      "$SONARR_URL/api/v3/command/$COMMAND_ID")
    echo "$RESPONSE"

    STATUS=$(jq -r '.status' <<< "$RESPONSE")
    RESULT=$(jq -r '.result' <<< "$RESPONSE")

    echo "Sonarr Command Status: $STATUS"

    if [[ "$STATUS" == "completed" ]]; then
        echo "File was imported successfully. Continuing..."
        break
    fi

    echo "File hasn't been imported yet. Checking again in 5 seconds"
    sleep 5
done

if [[ $RESULT != "successful" ]]; then
  echo "Import failed for some reason. Exiting Script."
  exit 1
fi

sleep 1
echo "Setting ReleaseGroup of new file to the same of the original file"
echo "UPDATE EpisodeFiles SET ReleaseGroup='$RELEASE_GROUP' WHERE RelativePath = '$REL_PATH'"
sqlite3 -noheader -batch $SONARR_DB_PATH \
  "UPDATE EpisodeFiles SET ReleaseGroup='$RELEASE_GROUP' WHERE RelativePath = '$REL_PATH'"

sleep 1
echo "Rescanning series to retrieve updated Release Group"
curl -X POST \
  -H "X-Api-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  "$SONARR_URL/api/v3/command" \
  -d "{\"name\":\"RefreshSeries\",\"seriesId\":$SERIES_ID}"

echo "Script is completed."
exit 0
