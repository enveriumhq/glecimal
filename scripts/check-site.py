#!/usr/bin/env python3
"""Check site/ for what a browser would not complain about: every in-page
link has a target, headings never skip a level, images have alt text, every
file the page refers to exists, the structured data parses and names
Enverium as publisher, and nothing breaks the content security policy (no
inline style or executable script, no off-site stylesheet or icon). Exits 1
with the problems listed."""

import json
import sys
from html.parser import HTMLParser
from pathlib import Path

SITE = Path(__file__).resolve().parent.parent / "site"
REQUIRED_LINKS = {
    "https://hex.pm/packages/glecimal",
    "https://hexdocs.pm/glecimal/",
    "https://github.com/enveriumhq/glecimal",
    "https://www.enverium.com/",
}
SITE_URL = "https://glecimal.com/"


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids, self.anchors, self.links, self.problems = set(), [], set(), []
        self.level = 0
        self.files, self.structured, self.in_structured = set(), [], False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if "style" in attrs or any(name.startswith("on") for name in attrs):
            self.problems.append(f"inline style or handler on <{tag}>")
        if tag == "script" and attrs.get("type") == "application/ld+json":
            self.in_structured = True
            self.structured.append("")
        elif tag in ("script", "style", "iframe", "form"):
            self.problems.append(f"<{tag}> is not allowed")
        if tag == "link" and attrs.get("href", "").startswith("/"):
            self.files.add(attrs["href"])
        if tag == "meta" and attrs.get("property") == "og:image":
            self.files.add("/" + attrs.get("content", "").removeprefix(SITE_URL))
        if tag == "img" and not attrs.get("alt"):
            self.problems.append("an <img> has no alt text")
        if tag == "link" and attrs.get("rel") in ("stylesheet", "icon"):
            if not attrs.get("href", "").startswith("/"):
                self.problems.append(f"off-site {attrs.get('rel')}: {attrs.get('href')}")
        if tag == "a":
            href = attrs.get("href", "")
            if href.startswith("#"):
                self.anchors.append(href[1:])
            elif href.startswith("http:"):
                self.problems.append(f"insecure link {href}")
            self.links.add(href)
        if len(tag) == 2 and tag[0] == "h" and tag[1].isdigit():
            level = int(tag[1])
            if level > self.level + 1:
                self.problems.append(f"<{tag}> follows <h{self.level}>")
            self.level = level


    def handle_data(self, data):
        if self.in_structured:
            self.structured[-1] += data

    def handle_endtag(self, tag):
        if tag == "script":
            self.in_structured = False


def check_structured(name: str, blocks: list) -> list:
    problems = []
    for block in blocks:
        try:
            data = json.loads(block)
        except json.JSONDecodeError as error:
            problems.append(f"{name}: structured data does not parse: {error}")
            continue
        publisher = data.get("publisher", {}).get("url")
        if publisher != REQUIRED_LINKS_ENVERIUM:
            problems.append(f"{name}: structured data publisher is {publisher}")
    return problems


REQUIRED_LINKS_ENVERIUM = "https://www.enverium.com/"


def check(path: Path, required: set) -> list:
    page = Page()
    page.feed(path.read_text(encoding="utf-8"))
    problems = [f"{path.name}: {p}" for p in page.problems]
    problems += [f"{path.name}: #{a} has no target" for a in page.anchors if a not in page.ids]
    problems += [f"{path.name}: no link to {link}" for link in required - page.links]
    problems += [f"{path.name}: {f} does not exist" for f in page.files if not (SITE / f.lstrip("/")).is_file()]
    problems += check_structured(path.name, page.structured)
    if required and not page.structured:
        problems.append(f"{path.name}: no structured data")
    return problems


def main() -> int:
    problems = check(SITE / "index.html", REQUIRED_LINKS) + check(SITE / "404.html", set())
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
