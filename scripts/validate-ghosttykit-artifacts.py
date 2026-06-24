#!/usr/bin/env python3

from __future__ import annotations

from pathlib import PurePosixPath
import sys
import tarfile


ARCHIVES = {
  "xcframework": ("GhosttyKit.xcframework",),
  "resources": ("ghostty", "terminfo"),
}


def normalize(name: str) -> str:
  while name.startswith("./"):
    name = name[2:]
  return name.rstrip("/")


def is_safe_member(name: str) -> bool:
  path = PurePosixPath(name)
  return not path.is_absolute() and ".." not in path.parts


def is_allowed(name: str, roots: tuple[str, ...]) -> bool:
  return any(name == root or name.startswith(root + "/") for root in roots)


def validate(archive_kind: str, archive_path: str) -> None:
  roots = ARCHIVES[archive_kind]
  seen_roots: set[str] = set()

  with tarfile.open(archive_path, "r:gz") as tar:
    for member in tar.getmembers():
      name = normalize(member.name)
      if not name:
        continue
      if not is_safe_member(name):
        raise SystemExit(f"unsafe archive entry: {member.name}")
      if not is_allowed(name, roots):
        raise SystemExit(f"unexpected archive entry: {member.name}")

      for root in roots:
        if name == root or name.startswith(root + "/"):
          seen_roots.add(root)

      if member.islnk() or member.issym():
        target = normalize(member.linkname)
        if not target or not is_safe_member(target):
          raise SystemExit(f"unsafe archive link target: {member.linkname}")
      elif not (member.isfile() or member.isdir()):
        raise SystemExit(f"unsupported archive member: {member.name}")

  missing = set(roots) - seen_roots
  if missing:
    raise SystemExit(f"archive missing roots: {', '.join(sorted(missing))}")


def main() -> None:
  if len(sys.argv) != 3 or sys.argv[1] not in ARCHIVES:
    kinds = "|".join(sorted(ARCHIVES))
    raise SystemExit(f"usage: validate-ghosttykit-artifacts.py <{kinds}> <archive.tar.gz>")

  validate(sys.argv[1], sys.argv[2])


if __name__ == "__main__":
  main()
