#!/bin/bash
# Prints the UDID of an available iPhone simulator on the newest iOS runtime this Xcode can run: no newer than its
# iOS Simulator SDK (the image can hold runtimes from other Xcode versions) and no older than the deployment target,
# 27.0. A standard model ("iPhone 18", then "iPhone 18 Pro" and the like) is preferred to any other iPhone: on 12 Nov
# the first iPhone listed was "iPhone Duo", a wide model whose tabs are a side strip rather than a tab bar and whose
# Simulator was slow enough under the UI tests to stall them (#139). Every candidate is printed to stderr. From simctl's
# JSON, with the python3 that ships with the image. Used by app.yml's jobs.
set -euo pipefail
sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
echo "iOS Simulator SDK: $sdk" >&2
xcrun simctl list devices available -j | python3 -c '
import json, re, sys
sdk = tuple(int(x) for x in sys.argv[1].split(".")[:2])
floor = (27, 0)
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    m = re.search(r"\.iOS-(\d+)-(\d+)", runtime)
    return tuple(map(int, m.groups())) if m else None
usable = [r for r in devices if version(r) and floor <= version(r) <= sdk]
def preference(name):
    if re.fullmatch(r"iPhone \d+", name): return 0
    if re.fullmatch(r"iPhone \d+[A-Za-z]?( (Pro|Pro Max|Plus|Air))?", name): return 1
    return 2
for r in sorted(usable, key=version, reverse=True):
    phones = [d for d in devices[r] if d.get("isAvailable", True) and d["name"].startswith("iPhone")]
    if not phones: continue
    print(r, "iPhones:", ", ".join(d["name"] for d in phones), file=sys.stderr)
    chosen = min(phones, key=lambda d: preference(d["name"]))
    print(chosen["udid"]); print(r, "chosen:", chosen["name"], file=sys.stderr); sys.exit(0)
sys.exit(f"no available iPhone simulator on an iOS runtime from 27.0 to {sys.argv[1]}")
' "$sdk"
