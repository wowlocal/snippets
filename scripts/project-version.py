#!/usr/bin/env python3
"""Read/edit only the named app target's configurations; preserve pbxproj formatting."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Snippets.xcodeproj/project.pbxproj"


def configurations(path, platform):
    project = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))
    objects = project["objects"]
    name = {"macos": "Snippets", "ios": "Snippets iOS"}[platform]
    targets = [v for v in objects.values() if v.get("isa") == "PBXNativeTarget" and v.get("name") == name]
    if len(targets) != 1:
        raise ValueError(f"Expected exactly one {name} target")
    ids = objects[targets[0]["buildConfigurationList"]]["buildConfigurations"]
    values = {(objects[i]["buildSettings"]["MARKETING_VERSION"],
               str(objects[i]["buildSettings"]["CURRENT_PROJECT_VERSION"])) for i in ids}
    if len(values) != 1:
        raise ValueError(f"{name} configuration versions disagree")
    return ids, next(iter(values))


def update(path, platform, version, build):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Expected version X.Y.Z and a positive integer build")
    ids, _ = configurations(path, platform)
    text = path.read_text()
    for identifier in ids:
        pattern = rf"(\t\t{identifier} /\*[^\n]+\*/ = \{{\n)(.*?)(\n\t\t\}};)"
        def replace(match):
            body = match[2]
            for key, value in (("MARKETING_VERSION", version), ("CURRENT_PROJECT_VERSION", build)):
                body, count = re.subn(rf"({key} = )[^;]+;", rf"\g<1>{value};", body)
                if count != 1:
                    raise ValueError(f"Expected one {key} in {identifier}")
            return match[1] + body + match[3]
        text, count = re.subn(pattern, replace, text, flags=re.S)
        if count != 1:
            raise ValueError(f"Could not locate configuration {identifier}")
    path.write_text(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=["macos", "ios"])
    parser.add_argument("--set", metavar="X.Y.Z")
    parser.add_argument("--build", help="Optional project build floor (uploads resolve the next unused build)")
    parser.add_argument("--bump", choices=["major", "minor", "patch"])
    args = parser.parse_args()
    _, (version, build) = configurations(PROJECT, args.platform)
    if args.set and args.bump:
        parser.error("Choose --set or --bump")
    if args.bump:
        parts = list(map(int, version.split(".")))
        index = ["major", "minor", "patch"].index(args.bump)
        parts[index] += 1
        parts[index + 1:] = [0] * (2 - index)
        version = ".".join(map(str, parts))
        build = str(int(build) + 1)
    version = args.set or version
    build = args.build or build
    if args.set or args.bump or args.build:
        update(PROJECT, args.platform, version, build)
    print(json.dumps({"version": version, "build": build}))


if __name__ == "__main__":
    main()
