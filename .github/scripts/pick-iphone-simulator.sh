#!/bin/bash
# Prints the UDID of an iPhone simulator on the newest iOS runtime this Xcode can run: no newer than its iOS Simulator
# SDK (the image can hold runtimes from other Xcode versions) and no older than the deployment target, 27.0. A standard
# model ("iPhone 18", then "iPhone 18 Pro" and the like) is preferred to any other iPhone. When the runtime has none
# (on 12 Nov its only iPhone was "iPhone Duo", a wide model whose tabs and toolbar are a side strip; the loupe didn't
# open there under the UI tests, #139), one is created from the newest standard iPhone device type the runtime takes,
# and only if that fails is another iPhone used. Every candidate is printed to stderr. From simctl's JSON, with the
# python3 that ships with the image. Used by app.yml's jobs.
set -euo pipefail
sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
echo "iOS Simulator SDK: $sdk" >&2
xcrun simctl list devices available -j | python3 -c '
import json, re, subprocess, sys
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
def create_standard(runtime):
    """A new simulator of the newest standard iPhone device type the runtime accepts, or None."""
    listed = subprocess.run(["xcrun", "simctl", "list", "devicetypes", "-j"], capture_output=True, text=True)
    if listed.returncode != 0: return None
    types = [t for t in json.loads(listed.stdout).get("devicetypes", []) if re.fullmatch(r"iPhone \d+", t["name"])]
    for t in sorted(types, key=lambda t: int(t["name"].split()[1]), reverse=True):
        made = subprocess.run(["xcrun", "simctl", "create", "CI " + t["name"], t["identifier"], runtime],
                              capture_output=True, text=True)
        if made.returncode == 0 and made.stdout.strip():
            return made.stdout.strip(), t["name"]
        print(runtime, "could not create", t["name"] + ":", made.stderr.strip(), file=sys.stderr)
    return None
for r in sorted(usable, key=version, reverse=True):
    phones = [d for d in devices[r] if d.get("isAvailable", True) and d["name"].startswith("iPhone")]
    if not phones: continue
    print(r, "iPhones:", ", ".join(d["name"] for d in phones), file=sys.stderr)
    chosen = min(phones, key=lambda d: preference(d["name"]))
    if preference(chosen["name"]) == 2:
        created = create_standard(r)
        if created:
            print(created[0]); print(r, "created:", created[1], file=sys.stderr); sys.exit(0)
    print(chosen["udid"]); print(r, "chosen:", chosen["name"], file=sys.stderr); sys.exit(0)
sys.exit(f"no available iPhone simulator on an iOS runtime from 27.0 to {sys.argv[1]}")
' "$sdk"
