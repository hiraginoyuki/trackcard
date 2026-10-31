#!/usr/bin/env python3
"""Export annotated contact groups as causal classifier replay inputs.

Reads immutable recorder logs and annotations; writes only the requested export
and its source manifest. Session labels never replace contact-group labels.
"""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re


def reference(value, prefix):
    if not re.fullmatch(prefix + r"[1-9]\d*", value):
        raise argparse.ArgumentTypeError(f"Expected a {prefix} reference, got {value!r}")
    return value


def export(directory, sessions, ignored, output):
    directory = directory.resolve()
    output = output.resolve()
    if output.is_relative_to(directory):
        raise ValueError("Choose an output outside the recorder directory")
    hashes = {}

    def read(path):
        data = path.read_bytes()
        hashes[path.name] = hashlib.sha256(data).hexdigest()
        return data

    annotations = json.loads(read(directory / "annotations.json"))
    numbers = annotations["referenceNumbers"]
    reverse = {number: key for key, number in numbers.items()}
    examples = []
    encountered = set()
    manifest_sessions = []
    for session in sessions:
        key = reverse.get(int(session[1:]), "")
        if not key.startswith("session/"):
            raise ValueError(f"Unknown session {session}")
        attempt_id = key.split("/", 1)[1]
        path = directory / (attempt_id.lower() + ".json")
        attempt = json.loads(read(path))
        if attempt["id"] != attempt_id or attempt.get("contactIndex") is None:
            raise ValueError(f"{session} has an invalid or missing contact index")
        entries = [json.loads(line) for line in read(path.with_suffix(".jsonl")).splitlines() if line.strip()]
        if not any(entry.get("kind") == "header" and entry.get("attempt", {}).get("id") == attempt_id for entry in entries):
            raise ValueError(f"{session} raw-log header does not match its summary")
        source_frames = [entry["frame"] for entry in entries if "frame" in entry]
        manifest_sessions.append({"ref": session, "id": attempt_id, "startedAt": attempt["startedAt"],
                                  "state": annotations.get("sessionStates", {}).get(attempt_id, "Unmarked"),
                                  "droppedFrames": attempt["droppedFrames"]})
        for group in annotations["contactGroups"]:
            if group["attemptID"] != attempt_id:
                continue
            group_ref = "g" + str(numbers["group/" + group["id"]])
            encountered.add(group_ref)
            if group_ref in ignored:
                continue
            identities = [c for c in attempt["contactIndex"]["contacts"] if c["id"] in group["contactIDs"]]
            if not identities or len(identities) != len(group["contactIDs"]):
                raise ValueError(f"{group_ref} has missing contact lifetimes")
            device_ids = {c["deviceID"] for c in identities}
            if len(device_ids) != 1:
                raise ValueError(f"{group_ref} spans multiple devices")
            device_id = next(iter(device_ids))
            device = next(d for d in attempt["devices"] if d["id"] == device_id)
            start = min(c["start"] for c in identities)
            end = max(c["end"] for c in identities)
            frames = []
            for frame in source_frames:
                if frame["deviceID"] != device_id or not start <= frame["time"] <= end:
                    continue
                # Retain non-pair frames and every active contact on the device.
                # Removing them would hide lifts, third fingers, or replacement
                # paths and give the classifier evidence it cannot see live.
                active = sorted((c for c in frame["contacts"] if c["stage"] in (3, 4)), key=lambda c: c["id"])
                exported_frame = {"arrival": frame["time"], "sensor": frame["sourceTimestamp"],
                                  "ids": [c["id"] for c in active],
                                  "points": [[c["position"][0] * device["sizeMM"][0],
                                              c["position"][1] * device["sizeMM"][1]] for c in active],
                                  "orientations": [c["angle"] for c in active],
                                  "radii": [c["radiiMM"] for c in active],
                                  "forces": [c.get("force", 0) for c in active],
                                  "pointerOverPreview": frame.get("pointerOverPreview")}
                if "actionAvailability" in frame:
                    exported_frame["actionAvailability"] = frame["actionAvailability"]
                frames.append(exported_frame)
            if not frames:
                raise ValueError(f"{group_ref} has no raw frames")
            examples.append({"ref": group_ref, "session": session, "label": group["category"]["label"],
                             "start": start, "end": end, "frames": frames})
    if missing := ignored - encountered:
        raise ValueError(f"Ignored groups are absent from the selected sessions: {', '.join(sorted(missing))}")
    for filename, digest in hashes.items():
        if hashlib.sha256((directory / filename).read_bytes()).hexdigest() != digest:
            raise ValueError(f"{filename} changed during export; retry after saving finishes")
    manifest = {"schemaVersion": 1, "sessions": manifest_sessions, "ignoredGroups": sorted(ignored),
                "groups": len(examples), "labels": dict(Counter(e["label"] for e in examples)),
                "sourceHashes": hashes}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(examples, separators=(",", ":")) + "\n")
    output.with_suffix(".manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"Exported {len(examples)} groups: {manifest['labels']}; ignored {', '.join(sorted(ignored)) or 'none'}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recordings", type=Path,
                        default=Path.home() / "Library/Application Support/Trackcard/Gesture Recordings")
    parser.add_argument("--session", action="append", required=True, type=lambda value: reference(value, "s"))
    parser.add_argument("--ignore-group", action="append", default=[], type=lambda value: reference(value, "g"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        export(args.recordings, list(dict.fromkeys(args.session)), set(args.ignore_group), args.output)
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f"Export failed: {error}\n")
