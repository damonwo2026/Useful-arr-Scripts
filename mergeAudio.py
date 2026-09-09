#!/usr/bin/env python3
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
from scipy.ndimage import gaussian_filter1d
from scipy.signal import correlate


SAMPLE_RATE = 16000
WINDOW_SECONDS = 0.025
HOP_SECONDS = 0.010
ANALYSIS_SECONDS = 60
MAX_OFFSET = 30.0


LANGUAGE_ALIASES = {
    "ger": ["ger", "deu", "de"],
    "deu": ["ger", "deu", "de"],
    "de": ["ger", "deu", "de"],
    "eng": ["eng", "en", "enq"],
    "en": ["eng", "en", "enq"]
}


LANGUAGE_NAMES = {
    "ger": "German",
    "deu": "German",
    "de": "German",
    "eng": "English",
    "en": "English"
}


def check_command(command):
    if shutil.which(command) is None:
        print(f"Fehler: {command} wurde nicht gefunden.")
        sys.exit(1)


def run(command):
    return subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=True
    )


def get_streams(path):
    result = run([
        "ffprobe",
        "-v", "error",
        "-show_streams",
        "-of", "json",
        str(path)
    ])

    return json.loads(result.stdout)["streams"]


def get_audio_streams(path):
    return [
        stream
        for stream in get_streams(path)
        if stream.get("codec_type") == "audio"
    ]


def find_audio_stream(path, language):
    wanted = LANGUAGE_ALIASES.get(
        language.lower(),
        [language.lower()]
    )

    audio_streams = get_audio_streams(path)

    for index, stream in enumerate(audio_streams):
        lang = stream.get("tags", {}).get("language", "").lower()

        if lang in wanted:
            return index, stream

    if not audio_streams:
        raise RuntimeError(
            f"Keine Audiospur in {path} gefunden."
        )

    raise RuntimeError(
        f"Keine Audiospur mit Language Tag '{language}' in {path} gefunden."
    )


def get_duration(path):
    result = run([
        "ffprobe",
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        str(path)
    ])

    return float(result.stdout.strip())


def extract_audio(path, stream_index, start, duration):
    command = [
        "ffmpeg",
        "-v", "error",
        "-ss", str(start),
        "-t", str(duration),
        "-i", str(path),
        "-map", f"0:a:{stream_index}",
        "-ac", "1",
        "-ar", str(SAMPLE_RATE),
        "-f", "s16le",
        "pipe:1"
    ]

    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.decode(errors="replace")
        )

    return np.frombuffer(
        result.stdout,
        dtype=np.int16
    ).astype(np.float32)


def energy_envelope(audio):
    window = max(1, int(WINDOW_SECONDS * SAMPLE_RATE))
    hop = max(1, int(HOP_SECONDS * SAMPLE_RATE))

    if len(audio) < window:
        return np.array([])

    count = 1 + (len(audio) - window) // hop

    shape = (count, window)
    strides = (
        audio.strides[0] * hop,
        audio.strides[0]
    )

    frames = np.lib.stride_tricks.as_strided(
        audio,
        shape=shape,
        strides=strides
    )

    rms = np.sqrt(
        np.mean(frames ** 2, axis=1) + 1e-12
    )

    db = 20 * np.log10(rms + 1e-12)

    db -= np.mean(db)

    std = np.std(db)

    if std > 0:
        db /= std

    db = gaussian_filter1d(
        db,
        sigma=2
    )

    return db


def find_offset(base_energy, source_energy):
    length = min(
        len(base_energy),
        len(source_energy)
    )

    base_energy = base_energy[:length]
    source_energy = source_energy[:length]

    base_energy = base_energy - np.mean(base_energy)
    source_energy = source_energy - np.mean(source_energy)

    base_std = np.std(base_energy)
    source_std = np.std(source_energy)

    if base_std == 0 or source_std == 0:
        raise RuntimeError(
            "Zu wenig verwertbare Audioenergie."
        )

    base_energy /= base_std
    source_energy /= source_std

    corr = correlate(
        base_energy,
        source_energy,
        mode="full",
        method="fft"
    )

    center = len(source_energy) - 1
    peak = np.argmax(corr)

    lag = peak - center

    offset = lag * HOP_SECONDS

    return offset, corr[peak]


def analyze_segment(
    base_path,
    source_path,
    source_stream,
    start,
    duration
):
    base_audio = extract_audio(
        base_path,
        0,
        start,
        duration
    )

    source_audio = extract_audio(
        source_path,
        source_stream,
        start,
        duration
    )

    base_energy = energy_envelope(base_audio)
    source_energy = energy_envelope(source_audio)

    return find_offset(
        base_energy,
        source_energy
    )


def create_output(
    base_path,
    source_path,
    source_stream,
    language,
    offset,
    output_path
):
    base_audio_streams = get_audio_streams(base_path)
    base_audio_count = len(base_audio_streams)
    new_audio_index = base_audio_count

    language_lower = language.lower()
    language_name = LANGUAGE_NAMES.get(
        language_lower,
        language
    )

    if offset < 0:
        trim = abs(offset)

        audio_filter = (
            f"[1:a:{source_stream}]"
            f"atrim=start={trim:.6f},"
            f"asetpts=PTS-STARTPTS,"
            f"aresample=async=1"
            f"[syncaudio]"
        )
    else:
        delay_ms = int(round(offset * 1000))

        audio_filter = (
            f"[1:a:{source_stream}]"
            f"adelay={delay_ms}:all=1,"
            f"asetpts=PTS-STARTPTS,"
            f"aresample=async=1"
            f"[syncaudio]"
        )

    command = [
        "ffmpeg",
        "-y",
        "-i", str(base_path),
        "-i", str(source_path),
        "-filter_complex", audio_filter,
        "-map", "0:v?",
        "-map", "0:a?",
        "-map", "[syncaudio]",
        "-map", "0:s?",
        "-map", "0:t?",
        "-c:v", "copy"
    ]

    for audio_index in range(base_audio_count):
        command.extend([
            f"-c:a:{audio_index}",
            "copy"
        ])

    command.extend([
        f"-c:a:{new_audio_index}",
        "aac",
        f"-b:a:{new_audio_index}",
        "192k",
        "-c:s", "copy",
        "-c:t", "copy",
        f"-metadata:s:a:{new_audio_index}",
        f"language={language}",
        f"-metadata:s:a:{new_audio_index}",
        f"title={language_name}",
        "-map_metadata", "0",
        "-map_chapters", "0",
        str(output_path)
    ])

    subprocess.run(
        command,
        check=True
    )


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "base_video"
    )

    parser.add_argument(
        "audio_source"
    )

    parser.add_argument(
        "language"
    )

    parser.add_argument(
        "output"
    )

    args = parser.parse_args()

    check_command("ffmpeg")
    check_command("ffprobe")

    base_path = Path(args.base_video)
    source_path = Path(args.audio_source)
    output_path = Path(args.output)

    if not base_path.is_file():
        print(
            f"Fehler: Base-Video nicht gefunden: {base_path}"
        )
        sys.exit(1)

    if not source_path.is_file():
        print(
            f"Fehler: Audio-Quelle nicht gefunden: {source_path}"
        )
        sys.exit(1)

    source_stream, source_info = find_audio_stream(
        source_path,
        args.language
    )

    base_audio_streams = get_audio_streams(
        base_path
    )

    print(
        f"Base audio tracks: {len(base_audio_streams)}"
    )

    print(
        f"Selected source audio track: {source_stream}"
    )

    print(
        f"Source language: "
        f"{source_info.get('tags', {}).get('language', '')}"
    )

    duration = min(
        get_duration(base_path),
        get_duration(source_path)
    )

    segment_starts = [
        0,
        duration * 0.25,
        duration * 0.50,
        duration * 0.75
    ]

    offsets = []

    print(
        "Analyzing audio energy patterns..."
    )

    for start in segment_starts:
        segment_duration = min(
            ANALYSIS_SECONDS,
            duration - start
        )

        if segment_duration < 10:
            continue

        print(
            f"Analyzing {start:.1f}s - "
            f"{start + segment_duration:.1f}s..."
        )

        offset, correlation = analyze_segment(
            base_path,
            source_path,
            source_stream,
            start,
            segment_duration
        )

        print(
            f"  Offset: {offset:.3f}s "
            f"Correlation: {correlation:.2f}"
        )

        offsets.append(offset)

    if not offsets:
        print(
            "Fehler: Keine Analyseergebnisse."
        )
        sys.exit(1)

    print(
        f"\nDetected offsets: {offsets}"
    )

    median_offset = float(
        np.median(offsets)
    )

    valid_offsets = [
        offset
        for offset in offsets
        if abs(offset - median_offset) <= 0.5
    ]

    if not valid_offsets:
        print(
            "Fehler: Offset-Ergebnisse sind nicht konsistent."
        )
        sys.exit(1)

    final_offset = float(
        np.median(valid_offsets)
    )

    if abs(final_offset) > MAX_OFFSET:
        print(
            f"Fehler: Erkannter Offset von "
            f"{final_offset:.3f}s ist unplausibel."
        )
        sys.exit(1)

    print(
        f"Final offset: {final_offset:.3f}s"
    )

    print(
        "Muxing synchronized audio..."
    )

    create_output(
        base_path,
        source_path,
        source_stream,
        args.language,
        final_offset,
        output_path
    )

    print(
        f"Output: {output_path}"
    )


if __name__ == "__main__":
    main()

