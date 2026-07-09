#!/usr/bin/env python3
"""Generate Resources/<lang>.lproj/{Localizable,InfoPlist}.strings from l10n.json.

Single source of truth for Ringgo's localization. Edit Scripts/l10n/l10n.json,
then run:  python3 Scripts/l10n/gen-strings.py

Validates that every language carries the exact same set of printf format
specifiers (order + count) as the zh-Hans base for each key, so the runtime
String(format:) in L10n.f can never misfire on a mistranslated placeholder.
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(HERE, "l10n.json")
OUT = os.path.join(REPO, "Resources")
LANGS = ["zh-Hans", "en", "ja"]


def specs(s):
    """Ordered list of format specifiers; positional (%1$@) sorted by index."""
    found = []
    for m in re.finditer(r"%(?:(\d+)\$)?([@a-zA-Z])", s):
        pos, conv = m.group(1), m.group(2)
        found.append((int(pos) if pos else None, conv))
    if any(p is not None for p, _ in found):
        return tuple(conv for _, conv in sorted(found, key=lambda t: (t[0] or 0)))
    return tuple(conv for _, conv in found)


def esc(s):
    return (s.replace("\\", "\\\\").replace("\"", "\\\"")
             .replace("\n", "\\n").replace("\t", "\\t"))


def main():
    data = json.load(open(SRC, encoding="utf-8"))
    errors = []
    for section in ("strings", "infoplist"):
        for key, vals in data[section].items():
            base = specs(vals["zh-Hans"])
            for lang in LANGS:
                if lang not in vals:
                    errors.append(f"[{section}] {key}: missing lang {lang}")
                    continue
                if specs(vals[lang]) != base:
                    errors.append(f"[{section}] {key}: specifier mismatch "
                                  f"{lang}={specs(vals[lang])} vs base={base}")
    if errors:
        print("VALIDATION FAILED:")
        for e in errors:
            print("  " + e)
        sys.exit(1)

    for lang in LANGS:
        d = os.path.join(OUT, f"{lang}.lproj")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
            f.write("/* Ringgo — generated from Scripts/l10n/l10n.json. Do not edit by hand. */\n\n")
            for key, vals in data["strings"].items():
                if vals.get("ctx"):
                    f.write(f"/* {vals['ctx']} */\n")
                f.write(f"\"{key}\" = \"{esc(vals[lang])}\";\n")
        with open(os.path.join(d, "InfoPlist.strings"), "w", encoding="utf-8") as f:
            f.write("/* Ringgo — generated from Scripts/l10n/l10n.json. */\n\n")
            for key, vals in data["infoplist"].items():
                f.write(f"\"{key}\" = \"{esc(vals[lang])}\";\n")

    print(f"OK: {len(data['strings'])} strings x {len(LANGS)} langs "
          f"+ {len(data['infoplist'])} InfoPlist keys -> {OUT}/*.lproj")


if __name__ == "__main__":
    main()
