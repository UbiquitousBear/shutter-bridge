#!/usr/bin/env python3
"""Checks that AllPackages.xcworkspace and its AllPackageTests scheme cover every package and every test target.

app.yml builds and tests every package through that workspace (one build-for-testing, so each module is compiled
once), so a package missing from the workspace, or a test target missing from the scheme, would silently go untested
in the iOS Simulator. A new package or test target must be added to both; this fails the run until it is. AppUI's
test target must stay not parallelisable (#109).
"""
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parents[2]
problems = []

present = {p.parent.name for p in (root / "Packages").glob("*/Package.swift")}
workspace = ET.parse(root / "AllPackages.xcworkspace" / "contents.xcworkspacedata").getroot()
listed = set()
for ref in workspace.iter("FileRef"):
    location = ref.get("location", "")
    match = re.fullmatch(r"group:Packages/([^/]+)", location)
    if match:
        listed.add(match.group(1))
    else:
        problems.append(f"AllPackages.xcworkspace: unexpected FileRef {location!r}")
for name in sorted(present - listed):
    problems.append(f"Packages/{name} isn't in AllPackages.xcworkspace")
for name in sorted(listed - present):
    problems.append(f"AllPackages.xcworkspace lists Packages/{name}, which has no Package.swift")

expected = {}
for package in sorted(present):
    manifest = (root / "Packages" / package / "Package.swift").read_text(encoding="utf-8")
    for name in re.findall(r'\.testTarget\(\s*name:\s*"([^"]+)"', manifest):
        expected[name] = package

scheme_path = root / "AllPackages.xcworkspace" / "xcshareddata" / "xcschemes" / "AllPackageTests.xcscheme"
scheme = ET.parse(scheme_path).getroot()
testables = {}
for testable in scheme.iter("TestableReference"):
    ref = testable.find("BuildableReference")
    name = ref.get("BlueprintName")
    container = ref.get("ReferencedContainer", "")
    testables[name] = (container, testable.get("parallelizable"), testable.get("skipped"))
for name, package in sorted(expected.items()):
    if name not in testables:
        problems.append(f"AllPackageTests doesn't test {name} (Packages/{package})")
        continue
    container, parallelizable, skipped = testables[name]
    if container != f"container:Packages/{package}":
        problems.append(f"AllPackageTests: {name} names {container!r}, expected 'container:Packages/{package}'")
    if skipped != "NO":
        problems.append(f"AllPackageTests: {name} is skipped")
    if name == "AppUITests" and parallelizable != "NO":
        problems.append("AllPackageTests: AppUITests must not be parallelisable (#109)")
for name in sorted(set(testables) - set(expected)):
    problems.append(f"AllPackageTests tests {name}, which no Package.swift declares")

for problem in problems:
    print(f"::error::{problem}")
if not problems:
    print(f"{len(listed)} packages and {len(expected)} test targets are in AllPackages.xcworkspace and AllPackageTests")
sys.exit(1 if problems else 0)
