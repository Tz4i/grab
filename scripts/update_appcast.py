#!/usr/bin/env python3
"""Insert or replace a release's <item> entry in appcast.xml.

Called from scripts/release.sh after the DMG is built and signed with
Sparkle's sign_update tool. Deliberately does plain text/regex editing of
the XML rather than parsing it into a DOM and re-serializing -- appcast.xml
has a fixed, simple, hand-authored structure (see the file's own header
comment), and round-tripping it through xml.etree would risk reordering
attributes/namespace prefixes and producing large, hard-to-review diffs on
every release. A small regex-based insert keeps each release's diff to
exactly the new (or replaced) <item> block, nothing else.
"""
import argparse
import re
import sys

ITEM_TEMPLATE = """        <item>
            <title>Version {version}</title>
            <pubDate>{pub_date}</pubDate>
            <sparkle:version>{version}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{min_system_version}</sparkle:minimumSystemVersion>
            <enclosure url="{url}" sparkle:edSignature="{signature}" length="{length}" type="application/octet-stream" />
        </item>
"""

MARKER = "<!-- ITEMS MARKER: new release items are inserted right after this comment -->"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", required=True, help="Path to appcast.xml")
    parser.add_argument("--version", required=True, help="MARKETING_VERSION, e.g. 1.4.0")
    parser.add_argument("--url", required=True, help="GitHub release asset download URL")
    parser.add_argument("--signature", required=True, help="sparkle:edSignature from sign_update")
    parser.add_argument("--length", required=True, help="DMG byte size from sign_update")
    parser.add_argument("--min-system-version", required=True, dest="min_system_version")
    parser.add_argument("--pub-date", required=True, dest="pub_date", help="RFC 822 date string")
    args = parser.parse_args()

    with open(args.appcast, "r", encoding="utf-8") as f:
        content = f.read()

    if MARKER not in content:
        sys.exit(f"error: {args.appcast} is missing the ITEMS MARKER comment -- refusing to guess where to insert.")

    # Idempotent re-run safety: if this version already has an entry
    # (e.g. release.sh was re-run after a failed push), drop the old one
    # before inserting the new one rather than ending up with duplicates.
    version_pattern = re.escape(args.version)
    existing_item_pattern = re.compile(
        r"[ \t]*<item>\s*.*?<sparkle:shortVersionString>" + version_pattern +
        r"</sparkle:shortVersionString>.*?</item>\s*\n",
        re.DOTALL,
    )
    content = existing_item_pattern.sub("", content)

    new_item = ITEM_TEMPLATE.format(
        version=args.version,
        pub_date=args.pub_date,
        min_system_version=args.min_system_version,
        url=args.url,
        signature=args.signature,
        length=args.length,
    )
    content = content.replace(MARKER, MARKER + "\n" + new_item.rstrip("\n"))

    with open(args.appcast, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"Inserted appcast entry for version {args.version}.")


if __name__ == "__main__":
    main()
