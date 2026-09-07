# Useful-arr-Scripts
This repository is new. Several useful scripts will be uploaded in the next few weeks that I wrote for my media stack.

# createSuperRelease.sh /path/to/file: #
requires script: mergeAudio.py

Grabs a new release for the file through Sonarr, searching for a release that contains either a german audio stream or english audio stream depending on which one is missing from the release. Then pulls the audio stream from the new file and merges it with the original file while synchronizing it using audio energy scan. The original file is replaced with the new file.
