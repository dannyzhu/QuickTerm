#!/usr/bin/env python3
"""Build the Sparkle appcast for one QuickTerm release.

    update-appcast.py --out build/appcast.xml --version 1.6.8 --build 24 --min-system 15.4.0 \
        --dmg-url https://github.com/dannyzhu/QuickTerm/releases/download/v1.6.8/QuickTerm-1.6.8.dmg \
        --length 81586712 --signature <edSignature> --notes docs/releases/v1.6.8.md \
        --notes-link https://github.com/dannyzhu/QuickTerm/releases/tag/v1.6.8 \
        (--previous build/appcast-previous.xml | --first-release)
    update-appcast.py --self-test

Rules (docs/superpowers/specs/2026-09-25-auto-update-design.md §7): the new build number must be
strictly greater than every build already in the feed (a forgotten CURRENT_PROJECT_VERSION bump
would otherwise publish an update no client is ever offered); an item with the same build is
replaced; a version string may not reappear under another build; the feed keeps the newest 15
items; pubDate is in the one shape Sparkle parses; the description carries the English notes as
Markdown text declared plain-text (QuickTerm's own driver flattens it, nothing else renders it).
Written with ElementTree, so no CDATA and no hand escaping.
"""

import argparse
import os
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
PUBDATE = "%a, %d %b %Y %H:%M:%S %z"
KEEP = 15
ET.register_namespace("sparkle", SPARKLE)


def q(name):
    return "{%s}%s" % (SPARKLE, name)


def empty_feed():
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "QuickTerm"
    ET.SubElement(channel, "link").text = "https://github.com/dannyzhu/QuickTerm"
    ET.SubElement(channel, "description").text = "QuickTerm updates"
    return ET.ElementTree(rss)


def build_of(item):
    element = item.find(q("version"))
    try:
        return int(element.text.strip()) if element is not None and element.text else None
    except ValueError:
        return None


def pubdate_of(item):
    element = item.find("pubDate")
    try:
        return datetime.strptime(element.text.strip(), PUBDATE) if element is not None and element.text else None
    except ValueError:
        return None


def merge(tree, version, build, min_system, dmg_url, length, signature, notes, notes_link, now):
    channel = tree.getroot().find("channel")
    if channel is None:
        raise SystemExit("error: the appcast has no <channel>")
    for item in channel.findall("item"):
        other = build_of(item)
        short = item.find(q("shortVersionString"))
        if other is not None and other > build:
            raise SystemExit("error: build %d is not greater than build %d already in the feed: "
                             "bump CURRENT_PROJECT_VERSION" % (build, other))
        if other is not None and other == build:
            channel.remove(item)
            continue
        if short is not None and short.text == version:
            raise SystemExit("error: version %s is already in the feed as build %s" % (version, other))
    item = ET.Element("item")
    ET.SubElement(item, "title").text = "QuickTerm %s" % version
    ET.SubElement(item, "pubDate").text = now.strftime(PUBDATE)
    ET.SubElement(item, q("version")).text = str(build)
    ET.SubElement(item, q("shortVersionString")).text = version
    ET.SubElement(item, q("minimumSystemVersion")).text = min_system
    ET.SubElement(item, q("fullReleaseNotesLink")).text = notes_link
    ET.SubElement(item, "description", {q("descriptionFormat"): "plain-text"}).text = notes
    ET.SubElement(item, "enclosure", {
        "url": dmg_url,
        "length": str(length),
        "type": "application/x-apple-diskimage",
        q("edSignature"): signature,
    })
    children = list(channel)
    first_item = next((i for i, child in enumerate(children) if child.tag == "item"), len(children))
    channel.insert(first_item, item)
    # Newest first; an unparsable date counts as oldest; ties keep document order.
    oldest = datetime.min.replace(tzinfo=timezone.utc)
    ranked = sorted(enumerate(channel.findall("item")),
                    key=lambda pair: (pubdate_of(pair[1]) or oldest, -pair[0]), reverse=True)
    for _, old in ranked[KEEP:]:
        channel.remove(old)
    return tree


def write(tree, path):
    ET.indent(tree, space="  ")
    tree.write(path, xml_declaration=True, encoding="utf-8")


def self_test():
    def fixture(builds):
        tree = empty_feed()
        now = datetime(2026, 9, 1, tzinfo=timezone.utc)
        for i, build in enumerate(builds):
            merge(tree, "1.0.%d" % build, build, "15.4.0", "https://x/%d.dmg" % build, 1, "sig",
                  "notes %d" % build, "https://x/%d" % build, now + timedelta(days=i))
        return tree

    tree = fixture([23])
    merge(tree, "1.6.8", 24, "15.4.0", "https://x/24.dmg", 5, "s24", "## Notes", "https://x/24",
          datetime(2026, 9, 30, 12, 0, tzinfo=timezone.utc))
    items = tree.getroot().find("channel").findall("item")
    assert [build_of(i) for i in items] == [24, 23], "newest first"
    assert items[0].find("pubDate").text == "Wed, 30 Sep 2026 12:00:00 +0000", items[0].find("pubDate").text
    assert items[0].find("description").get(q("descriptionFormat")) == "plain-text"
    assert items[0].find("enclosure").get(q("edSignature")) == "s24"
    # Same build again: replaced, not duplicated.
    merge(tree, "1.6.8", 24, "15.4.0", "https://x/24b.dmg", 6, "s24b", "n", "https://x/24",
          datetime(2026, 10, 1, tzinfo=timezone.utc))
    items = tree.getroot().find("channel").findall("item")
    assert [build_of(i) for i in items] == [24, 23] and items[0].find("enclosure").get("length") == "6"
    # A build that is not greater fails.
    try:
        merge(fixture([23, 24]), "1.6.9", 24 - 2, "15.4.0", "https://x/22.dmg", 1, "s", "n", "https://x/22",
              datetime.now(timezone.utc))
        raise AssertionError("a lower build must fail")
    except SystemExit as error:
        assert "not greater" in str(error), error
    # The same version under another build fails.
    try:
        merge(fixture([23]), "1.0.23", 30, "15.4.0", "https://x/30.dmg", 1, "s", "n", "https://x/30",
              datetime.now(timezone.utc))
        raise AssertionError("a reused version must fail")
    except SystemExit as error:
        assert "already in the feed" in str(error), error
    # Pruning keeps the newest 15, and an unparsable date does not crash.
    big = fixture(list(range(1, 17)))
    channel = big.getroot().find("channel")
    channel.findall("item")[-1].find("pubDate").text = "not a date"
    merge(big, "2.0.0", 100, "15.4.0", "https://x/100.dmg", 1, "s", "n", "https://x/100",
          datetime(2027, 1, 1, tzinfo=timezone.utc))
    builds = [build_of(i) for i in channel.findall("item")]
    assert len(builds) == KEEP and builds[0] == 100 and 1 not in builds, builds
    # Round trip through a file.
    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "appcast.xml")
        write(tree, path)
        again = ET.parse(path)
        assert [build_of(i) for i in again.getroot().find("channel").findall("item")] == [24, 23]
        assert "sparkle:version" in open(path, encoding="utf-8").read()
    print("update-appcast.py: self-test OK")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--out")
    parser.add_argument("--version")
    parser.add_argument("--build", type=int)
    parser.add_argument("--min-system", default="15.4.0")
    parser.add_argument("--dmg-url")
    parser.add_argument("--length", type=int)
    parser.add_argument("--signature")
    parser.add_argument("--notes", help="path to the English release notes (Markdown)")
    parser.add_argument("--notes-link")
    parser.add_argument("--previous", help="the feed published with the previous release")
    parser.add_argument("--first-release", action="store_true", help="accept a missing --previous")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    required = ["out", "version", "build", "dmg_url", "length", "signature", "notes", "notes_link"]
    missing = [name for name in required if getattr(args, name) in (None, "")]
    if missing:
        parser.error("missing: " + ", ".join("--" + name.replace("_", "-") for name in missing))
    if args.previous and os.path.exists(args.previous):
        tree = ET.parse(args.previous)
    elif args.first_release:
        tree = empty_feed()
    else:
        raise SystemExit("error: no previous appcast at %r; pass --first-release for the very first one" % args.previous)
    with open(args.notes, encoding="utf-8") as handle:
        notes = handle.read()
    merge(tree, args.version, args.build, args.min_system, args.dmg_url, args.length, args.signature,
          notes, args.notes_link, datetime.now(timezone.utc))
    write(tree, args.out)
    print("appcast: %s" % args.out)


if __name__ == "__main__":
    main()
