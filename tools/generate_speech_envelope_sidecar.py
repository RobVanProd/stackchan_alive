import argparse
import json
import math
import os
import statistics
import struct
import wave
from datetime import datetime, timezone


def clamp(value, low, high):
    return max(low, min(high, value))


def percentile(values, p):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = (len(ordered) - 1) * p
    lower = int(math.floor(index))
    upper = int(math.ceil(index))
    if lower == upper:
        return ordered[lower]
    weight = index - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def decode_pcm(raw, sample_width):
    if sample_width == 1:
        return [(byte - 128) / 128.0 for byte in raw]

    if sample_width == 2:
        count = len(raw) // 2
        return [value / 32768.0 for value in struct.unpack("<" + "h" * count, raw[: count * 2])]

    if sample_width == 3:
        samples = []
        for index in range(0, len(raw) - 2, 3):
            value = raw[index] | (raw[index + 1] << 8) | (raw[index + 2] << 16)
            if value & 0x800000:
                value -= 0x1000000
            samples.append(value / 8388608.0)
        return samples

    if sample_width == 4:
        count = len(raw) // 4
        return [value / 2147483648.0 for value in struct.unpack("<" + "i" * count, raw[: count * 4])]

    raise ValueError(f"Unsupported sample width: {sample_width} bytes")


def read_wav_mono(path):
    with wave.open(path, "rb") as wav:
        channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        sample_rate = wav.getframerate()
        frame_count = wav.getnframes()
        compression = wav.getcomptype()
        if compression != "NONE":
            raise ValueError(f"Input WAV must be uncompressed PCM, got {compression}")
        raw = wav.readframes(frame_count)

    decoded = decode_pcm(raw, sample_width)
    if channels <= 1:
        mono = decoded
    else:
        mono = []
        for index in range(0, len(decoded) - channels + 1, channels):
            mono.append(sum(decoded[index : index + channels]) / channels)

    return {
        "samples": mono,
        "sample_rate": sample_rate,
        "channels": channels,
        "sample_width": sample_width,
        "frame_count": frame_count,
    }


def chunk_metrics(samples, frame_samples):
    metrics = []
    for start in range(0, len(samples), frame_samples):
        chunk = samples[start : start + frame_samples]
        if not chunk:
            continue

        square_sum = sum(sample * sample for sample in chunk)
        rms = math.sqrt(square_sum / len(chunk))
        peak = max(abs(sample) for sample in chunk)
        zero_crossings = 0
        previous = chunk[0]
        diff_square_sum = 0.0
        for sample in chunk[1:]:
            if (previous < 0.0 <= sample) or (previous >= 0.0 > sample):
                zero_crossings += 1
            diff = sample - previous
            diff_square_sum += diff * diff
            previous = sample
        zcr = zero_crossings / max(1, len(chunk) - 1)
        brightness = diff_square_sum / max(square_sum, 1.0e-9)
        metrics.append({"rms": rms, "peak": peak, "zcr": zcr, "brightness": brightness})
    return metrics


def smooth_envelopes(metrics, frame_ms):
    rms_values = [item["rms"] for item in metrics]
    noise_floor = percentile(rms_values, 0.10) * 1.4
    reference = max(percentile(rms_values, 0.95), noise_floor + 1.0e-5)
    attack_alpha = 1.0 - math.exp(-frame_ms / 20.0)
    release_alpha = 1.0 - math.exp(-frame_ms / 90.0)
    envelope = 0.0
    envelopes = []

    for item in metrics:
        normalized = clamp((item["rms"] - noise_floor) / (reference - noise_floor), 0.0, 1.0)
        alpha = attack_alpha if normalized > envelope else release_alpha
        envelope += (normalized - envelope) * alpha
        envelopes.append(clamp(envelope, 0.0, 1.0))

    return envelopes, noise_floor, reference


def choose_visemes(metrics, envelopes):
    voiced = [item for item, env in zip(metrics, envelopes) if env >= 0.08]
    zcr_low = percentile([item["zcr"] for item in voiced], 0.35)
    zcr_high = percentile([item["zcr"] for item in voiced], 0.70)
    bright_high = percentile([item["brightness"] for item in voiced], 0.66)
    visemes = []

    for item, env in zip(metrics, envelopes):
        if env < 0.04:
            visemes.append("neutral")
        elif item["zcr"] <= zcr_low and item["brightness"] < bright_high:
            visemes.append("oh")
        elif item["zcr"] >= zcr_high or item["brightness"] >= bright_high:
            visemes.append("ee")
        else:
            visemes.append("ah")
    return visemes


def build_sidecar(input_path, frame_ms):
    wav = read_wav_mono(input_path)
    frame_samples = max(1, int(round(wav["sample_rate"] * frame_ms / 1000.0)))
    metrics = chunk_metrics(wav["samples"], frame_samples)
    envelopes, noise_floor, reference = smooth_envelopes(metrics, frame_ms)
    visemes = choose_visemes(metrics, envelopes)
    frames = []

    for index, (item, envelope, viseme) in enumerate(zip(metrics, envelopes, visemes)):
        frames.append(
            {
                "tMs": index * frame_ms,
                "envelope": round(envelope, 3),
                "viseme": viseme,
                "rms": round(item["rms"], 6),
            }
        )

    duration_seconds = len(wav["samples"]) / wav["sample_rate"] if wav["sample_rate"] else 0.0
    voiced_frames = sum(1 for frame in frames if frame["envelope"] >= 0.04)
    return {
        "schema": "stackchan.speech-envelope-sidecar.v1",
        "sourceWav": os.path.normpath(input_path),
        "generatedUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "frameMs": frame_ms,
        "frameRateHz": round(1000.0 / frame_ms, 3),
        "sampleRate": wav["sample_rate"],
        "channels": wav["channels"],
        "sampleWidthBytes": wav["sample_width"],
        "durationSeconds": round(duration_seconds, 3),
        "normalization": {
            "noiseFloorRms": round(noise_floor, 8),
            "referenceRms": round(reference, 8),
            "attackMs": 20,
            "releaseMs": 90,
        },
        "summary": {
            "frames": len(frames),
            "voicedFrames": voiced_frames,
            "maxEnvelope": max((frame["envelope"] for frame in frames), default=0.0),
            "visemes": dict(sorted({name: visemes.count(name) for name in set(visemes)}.items())),
        },
        "frames": frames,
    }


def main():
    parser = argparse.ArgumentParser(description="Generate Stackchan speech-envelope sidecar JSON from a PCM WAV.")
    parser.add_argument("--input", required=True, help="Input PCM WAV path.")
    parser.add_argument("--output", required=True, help="Output sidecar JSON path.")
    parser.add_argument("--frame-ms", type=int, default=20, help="Frame size in milliseconds. Default: 20 (50 Hz).")
    args = parser.parse_args()

    if args.frame_ms < 10 or args.frame_ms > 100:
        raise ValueError("--frame-ms must be between 10 and 100")

    sidecar = build_sidecar(args.input, args.frame_ms)
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(sidecar, handle, indent=2)
        handle.write("\n")

    summary = sidecar["summary"]
    print(
        "Speech envelope sidecar written: "
        f"{args.output} ({summary['frames']} frames, max env {summary['maxEnvelope']:.3f})"
    )


if __name__ == "__main__":
    main()
