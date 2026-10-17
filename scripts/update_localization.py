#!/usr/bin/env python3
"""Scans Swift sources for localizable string literals and merges them into
Localizable.xcstrings, preserving existing translations and flagging missing ones.

Collects:
  - String(localized: "...")
  - Text("..."), Button("..."), Toggle("..."), TextField("...", ...) etc.
    (SwiftUI views taking a LocalizedStringKey string literal)

Handles Swift string interpolation with nested quotes:
  "\(shiftHours, specifier: "%.1f") hours"

Usage: python3 scripts/update_localization.py [--list-missing]
Exit code 1 when zh-Hans translations are missing (used as a completeness gate).
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "FranPhotos" / "Localizable.xcstrings"

MARKERS = [
    'String(localized: "',
    'Text("',
    'Button("',
    'Toggle("',
    'TextField("',
    'Stepper("',
    'Menu("',
    'Section("',
    '.help("',
    '.tabItem("',
    'prompt: Text("',
]


def parse_string_literal(text: str, start: int):
    """Parse a Swift string literal starting at index of the opening quote.
    Returns (key, end_index_after_closing_quote) or None."""
    if start >= len(text) or text[start] != '"':
        return None
    i = start + 1
    buf = []
    depth = 0
    while i < len(text):
        c = text[i]
        if c == '\\' and i + 1 < len(text):
            nxt = text[i + 1]
            if nxt == '(':
                depth += 1
                buf.append('\\(')
                i += 2
                continue
            buf.append(text[i:i + 2])
            i += 2
            continue
        if c == '(' and depth > 0:
            depth += 1
        elif c == ')' and depth > 0:
            depth -= 1
        elif c == '"' and depth == 0:
            return ''.join(buf), i + 1
        buf.append(c)
        i += 1
    return None


def collect_keys():
    keys = set()
    for swift in (ROOT / "FranPhotos").rglob("*.swift"):
        text = swift.read_text(encoding="utf-8")
        for marker in MARKERS:
            start = 0
            while True:
                idx = text.find(marker, start)
                if idx == -1:
                    break
                quote_at = idx + len(marker) - 1
                parsed = parse_string_literal(text, quote_at)
                if parsed is None:
                    start = quote_at + 1
                    continue
                key, end = parsed
                # Skip empty and purely-symbolic keys
                if key.strip():
                    keys.add(key.replace('\\"', '"'))
                start = end
    return keys


def main():
    keys = collect_keys()
    catalog = json.loads(CATALOG.read_text(encoding="utf-8")) if CATALOG.exists() else {
        "sourceLanguage": "en", "strings": {}, "version": "1.0"
    }
    strings = catalog.setdefault("strings", {})
    for key in sorted(keys):
        entry = strings.setdefault(key, {})
        entry.setdefault("localizations", {})
    stale = [k for k in strings if k not in keys]
    for k in stale:
        del strings[k]
    missing = []
    for k in sorted(keys):
        unit = (strings[k].get("localizations", {})
                .get("zh-Hans", {}).get("stringUnit", {}))
        if unit.get("state") != "translated" or not unit.get("value"):
            missing.append(k)
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True),
                       encoding="utf-8")
    print(f"keys in code: {len(keys)}; catalog: {len(strings)}; pruned: {len(stale)}")
    print(f"missing zh-Hans: {len(missing)}")
    if "--list-missing" in sys.argv:
        for k in missing:
            print("  - " + k)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
