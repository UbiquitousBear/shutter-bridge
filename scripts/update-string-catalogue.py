#!/usr/bin/env python3
"""Brings AppUI's String Catalog in step with the keys its code uses (I17).

AppUI's user-facing strings go through `AppText` (Packages/AppUI/Sources/AppUI/AppText.swift), keyed by their
British English text: `AppText.string("…")`, `AppText.format("…", …)` and `AppText.counted(n, one: "…", other: "…")`.
This script finds those calls in Packages/AppUI/Sources/AppUI, adds every key the catalogue lacks with its en-GB
value (the plural variants for a counted phrase), and removes the entries no call uses any more. Entries that are
kept are left as they are, translations included, and so are entries Xcode extracted by itself from a SwiftUI `Text`
literal (those without the "manual" extraction state). `AppTextCatalogueTests` checks the same thing on every test run,
so run this after adding or changing a string, then `make test`.

    python3 scripts/update-string-catalogue.py          # rewrite the catalogue
    python3 scripts/update-string-catalogue.py --check  # exit 1 if it is out of step
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Packages" / "AppUI" / "Sources" / "AppUI"
CATALOGUE = SOURCES / "Resources" / "Localizable.xcstrings"
LANGUAGE = "en-GB"


def parse_literal(src, i):
    """Parses the Swift string literal starting at src[i] == '"'. Returns (value, end, has_interpolation)."""
    assert src[i] == '"'
    if src.startswith('"""', i):
        raise ValueError("multi-line string literal")
    i += 1
    out = []
    interpolated = False
    while True:
        c = src[i]
        if c == '"':
            return "".join(out), i + 1, interpolated
        if c == "\n":
            raise ValueError("unterminated string literal")
        if c == "\\":
            n = src[i + 1]
            if n == "(":
                interpolated = True
                depth = 1
                i += 2
                while depth:
                    if src[i] == '"':
                        _, i, _ = parse_literal(src, i)
                        continue
                    depth += {"(": 1, ")": -1}.get(src[i], 0)
                    i += 1
                continue
            if n == "u":
                close = src.index("}", i)
                out.append(chr(int(src[i + 3:close], 16)))
                i = close + 1
                continue
            out.append({"n": "\n", "t": "\t", "0": "\0", "r": "\r"}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1


def skip_space(src, i):
    while i < len(src) and src[i] in " \t\r\n":
        i += 1
    return i


def parse_chain(src, i):
    """Parses literals joined by `+` starting at src[i]. Returns (value, end)."""
    parts = []
    while True:
        i = skip_space(src, i)
        if i >= len(src) or src[i] != '"':
            raise ValueError("expected a string literal")
        value, i, interpolated = parse_literal(src, i)
        if interpolated:
            raise ValueError("a key may not interpolate: use AppText.format with %@")
        parts.append(value)
        j = skip_space(src, i)
        if j < len(src) and src[j] == "+":
            i = j + 1
            continue
        return "".join(parts), i


def calls(src):
    """Yields (kind, key, one) for every AppText call in `src`; `one` only for counted phrases."""
    i = 0
    while True:
        i = src.find("AppText.", i)
        if i < 0:
            return
        rest = src[i + len("AppText."):]
        for kind in ("string(", "format(", "counted("):
            if rest.startswith(kind):
                break
        else:
            i += 1
            continue
        i += len("AppText.") + len(kind)
        if kind == "counted(":
            one_at = src.index("one:", i)
            one, j = parse_chain(src, one_at + len("one:"))
            j = skip_space(src, j)
            if src[j] != ",":
                raise ValueError("expected `, other:` after `one:`")
            j = skip_space(src, j + 1)
            if not src.startswith("other:", j):
                raise ValueError("expected `other:`")
            other, i = parse_chain(src, j + len("other:"))
            yield "counted", other, one
        else:
            key, i = parse_chain(src, i)
            yield kind[:-1], key, None


def source_keys():
    keys = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        if path.name == "AppText.swift":
            continue
        src = path.read_text(encoding="utf-8")
        # Leave out comments so documentation examples aren't taken for keys.
        lines = [line.split("//")[0] if line.lstrip().startswith("//") else line for line in src.split("\n")]
        for kind, key, one in calls("\n".join(lines)):
            previous = keys.get(key)
            if previous and previous != (kind, one):
                raise ValueError(f"{key!r} is used as {previous} and as {(kind, one)}")
            keys[key] = (kind, one)
    return keys


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def entry(kind, key, one):
    if kind == "counted":
        localization = {"variations": {"plural": {"one": unit(one), "other": unit(key)}}}
    else:
        localization = unit(key)
    return {"extractionState": "manual", "localizations": {LANGUAGE: localization}}


def main():
    check = "--check" in sys.argv[1:]
    keys = source_keys()
    catalogue = {"sourceLanguage": LANGUAGE, "strings": {}, "version": "1.0"}
    if CATALOGUE.exists():
        catalogue = json.loads(CATALOGUE.read_text(encoding="utf-8"))
    strings = catalogue["strings"]
    updated = {}
    for key, (kind, one) in keys.items():
        wanted = entry(kind, key, one)
        current = strings.get(key)
        if current and current.get("localizations", {}).get(LANGUAGE) == wanted["localizations"][LANGUAGE]:
            updated[key] = current
        else:
            merged = dict(current or {})
            merged["extractionState"] = "manual"
            merged.setdefault("localizations", {})[LANGUAGE] = wanted["localizations"][LANGUAGE]
            updated[key] = merged
    for key, current in strings.items():
        if key not in updated and current.get("extractionState") != "manual":
            updated[key] = current
    catalogue["strings"] = updated
    text = json.dumps(catalogue, indent=2, ensure_ascii=False, sort_keys=True, separators=(",", " : ")) + "\n"
    old = CATALOGUE.read_text(encoding="utf-8") if CATALOGUE.exists() else ""
    if check:
        if text != old:
            print(f"{CATALOGUE.relative_to(ROOT)} is out of step with the code: run scripts/update-string-catalogue.py")
            return 1
        return 0
    CATALOGUE.parent.mkdir(parents=True, exist_ok=True)
    CATALOGUE.write_text(text, encoding="utf-8")
    added = len(set(updated) - set(strings))
    removed = len(set(strings) - set(updated))
    print(f"{len(updated)} strings ({added} added, {removed} removed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
