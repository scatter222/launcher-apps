#!/usr/bin/env python3
"""Generate the tool catalog (config/tools.json) from the tool-configs markdown
references.

The four `*_tools_complete.md` files in the `tool-configs` repo are the source
of truth. This script parses their category/subcategory/tool structure into a
single JSON catalog consumed by the API's ToolsService.

Usage:
    generate-tools-catalog.py [--src DIR] [--out FILE]

    --src   Directory containing the *_tools_complete.md files
            (default: ../../../tool-configs relative to this script,
             i.e. a sibling checkout of the tool-configs repo).
    --out   Output JSON path
            (default: <repo>/api/src/LauncherApi/config/tools.json).

The catalog is informational only: it records which tools exist on which
analysis VM so users can explore what is available by category. Tools are not
launched from the launcher — each runs on its own VM.
"""
import argparse
import json
import re
import sys
from pathlib import Path

SYSTEMS = [
    {
        "id": "flare-vm",
        "name": "FLARE-VM",
        "os": "Windows",
        "description": "Windows-based malware analysis and reverse engineering environment by Mandiant's FLARE team, managed with Chocolatey.",
        "packageManager": "Chocolatey",
        "source": "https://github.com/mandiant/flare-vm",
        "file": "flare_vm_tools_complete.md",
    },
    {
        "id": "parrot-os",
        "name": "Parrot OS Security Edition",
        "os": "Linux (Debian)",
        "description": "Debian-based Linux distribution for penetration testing, digital forensics, reverse engineering, and privacy.",
        "packageManager": "apt",
        "source": "https://www.parrotsec.org",
        "file": "parrot_os_tools_complete.md",
    },
    {
        "id": "remnux",
        "name": "REMnux",
        "os": "Linux (Ubuntu)",
        "description": "Linux toolkit for reverse-engineering and analyzing malicious software, based on Ubuntu.",
        "packageManager": "apt",
        "source": "https://docs.remnux.org",
        "file": "remnux_tools_complete.md",
    },
    {
        "id": "sift",
        "name": "SIFT Workstation",
        "os": "Linux (Ubuntu 22.04)",
        "description": "SANS Investigative Forensic Toolkit — a free, open-source DFIR workstation built on Ubuntu.",
        "packageManager": "apt / SaltStack",
        "source": "https://www.sans.org/tools/sift-workstation",
        "file": "sift_tools_complete.md",
    },
]

CATEGORY_RE = re.compile(r"^##\s+\d+\.\s+(.*?)\s*$")
SUBCATEGORY_RE = re.compile(r"^#{3,4}\s+\d+\.\d+\s+(.*?)\s*$")
HEADER_RE = re.compile(r"^(#{3,4})\s+(.*?)\s*$")


def slugify(text):
    text = text.lower()
    text = re.sub(r"[`*]", "", text)
    text = re.split(r"[/(]", text)[0]
    text = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    return text or "tool"


def clean_name(raw):
    name = raw.replace("`", "").replace("⭐", "")
    name = re.sub(r"\(default\)", "", name, flags=re.IGNORECASE)
    name = re.sub(r"\s+", " ", name).strip(" /")
    return name.strip()


def parse_file(src, system):
    lines = (src / system["file"]).read_text(encoding="utf-8").splitlines()
    tools = []
    category = None
    subcategory = None
    in_toc = False
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]

        if line.strip().lower() == "## table of contents":
            in_toc = True
            i += 1
            continue

        cat_m = CATEGORY_RE.match(line)
        if cat_m:
            in_toc = False
            category = cat_m.group(1).strip()
            subcategory = None
            i += 1
            continue
        if line.startswith("## "):
            in_toc = False
            capm = re.match(r"^##\s+\d+\.\s+(.*)$", line)
            if capm:
                category = capm.group(1).strip()
                subcategory = None
            i += 1
            continue

        if in_toc:
            i += 1
            continue

        sub_m = SUBCATEGORY_RE.match(line)
        if sub_m:
            subcategory = sub_m.group(1).strip()
            i += 1
            continue

        h_m = HEADER_RE.match(line)
        if h_m and category:
            raw = h_m.group(2)
            name = clean_name(raw)
            if not name:
                i += 1
                continue
            is_default = "⭐" in raw
            aliases = [clean_name(a) for a in re.split(r"\s*/\s*", raw) if clean_name(a)]

            j = i + 1
            desc_lines = []
            example = None
            while j < n and lines[j].strip() == "":
                j += 1
            while j < n:
                lj = lines[j]
                s = lj.strip()
                if s == "" or s.startswith("```") or HEADER_RE.match(lj) or lj.startswith("## ") or s == "---":
                    break
                desc_lines.append(s)
                j += 1

            k = j
            comment_fallback = None
            while k < n:
                lk = lines[k]
                if HEADER_RE.match(lk) or lk.startswith("## "):
                    break
                if lk.strip().startswith("```"):
                    k += 1
                    while k < n and not lines[k].strip().startswith("```"):
                        cmd = lines[k].strip()
                        if cmd and not cmd.startswith("#") and not cmd.startswith("//"):
                            example = cmd
                            break
                        if comment_fallback is None and cmd.startswith("#") and len(cmd) > 2:
                            comment_fallback = cmd.lstrip("# ").strip()
                        k += 1
                    break
                k += 1

            description = " ".join(desc_lines).strip()
            if not description and comment_fallback:
                description = comment_fallback
            if len(description) > 700:
                description = description[:697].rstrip() + "..."

            tools.append({
                "name": name,
                "aliases": aliases if len(aliases) > 1 else [],
                "system": system["id"],
                "category": category,
                "subcategory": subcategory,
                "description": description,
                "default": is_default,
                "example": example,
                "_slug": slugify(raw),
            })
            i = j
            continue
        i += 1
    return tools


def build_catalog(src):
    all_tools = []
    counts = {}
    for system in SYSTEMS:
        t = parse_file(src, system)
        counts[system["id"]] = len(t)
        all_tools.extend(t)

    # backfill empty descriptions: reuse a same-named tool's, else the header parenthetical
    by_name = {}
    for t in all_tools:
        if t["description"] and t["name"].lower() not in by_name:
            by_name[t["name"].lower()] = t["description"]
    for t in all_tools:
        if not t["description"]:
            t["description"] = by_name.get(t["name"].lower(), "")
        if not t["description"]:
            m = re.search(r"\(([^)]+)\)", t["name"])
            if m:
                t["description"] = f"Toolset: {m.group(1)}."

    seen = {}
    ordered = []
    for t in all_tools:
        base = f"{t['system']}-{t.pop('_slug')}"
        if base in seen:
            seen[base] += 1
            t["id"] = f"{base}-{seen[base]}"
        else:
            seen[base] = 1
            t["id"] = base
        ordered.append({
            "id": t["id"],
            "name": t["name"],
            "aliases": t["aliases"],
            "system": t["system"],
            "category": t["category"],
            "subcategory": t["subcategory"],
            "description": t["description"],
            "default": t["default"],
            "example": t["example"],
        })

    catalog = {
        "version": 1,
        "description": "Catalog of security/forensics tooling available across the lab's analysis VMs. Informational only — tools run on their respective VMs; this catalog lets users explore what is available by category.",
        "systems": [{k: v for k, v in s.items() if k != "file"} for s in SYSTEMS],
        "tools": ordered,
    }
    return catalog, counts


def main():
    here = Path(__file__).resolve()
    repo_root = here.parents[2]  # api/scripts/ -> api/ -> repo
    default_out = repo_root / "api/src/LauncherApi/config/tools.json"
    default_src = repo_root.parent / "tool-configs"

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", type=Path, default=default_src,
                    help="Directory with the *_tools_complete.md files")
    ap.add_argument("--out", type=Path, default=default_out,
                    help="Output JSON path")
    args = ap.parse_args()

    missing = [s["file"] for s in SYSTEMS if not (args.src / s["file"]).exists()]
    if missing:
        sys.exit(f"error: missing source files in {args.src}: {', '.join(missing)}")

    catalog, counts = build_catalog(args.src)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    total = sum(counts.values())
    print(f"Wrote {total} tools across {len(SYSTEMS)} systems to {args.out}")
    for k, v in counts.items():
        print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
