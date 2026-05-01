#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
import tarfile
import sys
import uuid
from typing import List, Optional, Callable, Dict
from dataclasses import dataclass, asdict

#### Schemas


@dataclass
class CachedVersionsSchema:
    installed: Optional[str] = None
    cached: Optional[str] = None

    @classmethod
    def from_dict(cls, data: dict) -> "CachedVersionsSchema":
        return cls(installed=data.get("installed"), cached=data.get("cached"))

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class MetadataSchema:
    versions: Dict[str, CachedVersionsSchema]
    delete_later: List[str] = None

    def __post_init__(self):
        if self.delete_later is None:
            self.delete_later = []

    @classmethod
    def from_dict(cls, data: dict) -> "MetadataSchema":
        versions_data = data.get("versions", {})
        versions = {
            k: CachedVersionsSchema.from_dict(v) for k, v in versions_data.items()
        }
        delete_later = data.get("delete_later", [])
        return cls(versions=versions, delete_later=delete_later)

    def to_dict(self) -> dict:
        return {
            "versions": {k: v.to_dict() for k, v in self.versions.items()},
            "delete_later": self.delete_later,
        }


#### Constants

ANSI_RESET = "\033[0m"
ANSI_GRAY  = "\033[90m"


#### Manager objects


class Package:
    def __init__(
        self,
        func: Callable[[], None],
        *,
        name: str,
        tags: Optional[List[str]] = None,
        version=None,
    ) -> None:
        self.func = func
        self.name = name
        self.tags: List[str] = tags if tags is not None else []
        self._version_expr = version  # value or callable
        self.cached_versions = CachedVersionsSchema()

    def install(self, force: bool) -> None:
        if not force and self.cached_versions.installed == self.cached_versions.cached:
            return
        self.func()
        ver = self.get_current_version()
        if ver is not None:
            self.cached_versions.installed = ver
            self.cached_versions.cached = ver

    def get_current_version(self) -> Optional[str]:
        """Return the current version of this package by evaluating its version expression."""
        if self._version_expr is None:
            return None
        if callable(self._version_expr):
            return self._version_expr(self)  # call with the package object
        return self._version_expr


class Manager:
    def __init__(self) -> None:
        self.packages: Dict[str, Package] = {}
        self._pkg_json_path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "pkg.json"
        )
        self.package_versions: Dict[str, dict] = {}
        self.delete_later: List[str] = []

    ### Public methods

    #### Definitions

    def package(self, **kwargs) -> Callable:
        def decorator(func: Callable[[], None]) -> Callable[[], None]:
            pkg = Package(func, **kwargs)
            self.packages[pkg.name] = pkg
            data = self.package_versions.get(pkg.name)
            if isinstance(data, dict):
                pkg.cached_versions.installed = data.get("installed")
                pkg.cached_versions.cached = data.get("cached")
            return func

        return decorator

    #### Process execution

    def run(self, args: list, **kwargs) -> subprocess.CompletedProcess:
        cmd_str = " ".join(args)
        print(f"{ANSI_GRAY}{cmd_str}{ANSI_RESET}")
        return subprocess.run(args, **kwargs)

    def extract(self, target: str, source: str) -> None:
        if tarfile.is_tarfile(source):
            with tarfile.open(source) as tar:
                members = tar.getmembers()
                top_level = {m.name.split('/')[0] for m in members}
                
                if len(top_level) > 1:
                    os.makedirs(target, exist_ok=True)
                    tar.extractall(target)
                elif len(top_level) == 1:
                    root_name = list(top_level)[0]
                    root_member = next(m for m in members if m.name.startswith(root_name))
                    
                    if root_member.isdir():
                        import tempfile
                        with tempfile.TemporaryDirectory() as tmp:
                            tar.extractall(tmp)
                            os.makedirs(target, exist_ok=True)
                            src_dir = os.path.join(tmp, root_name)
                            for item in os.listdir(src_dir):
                                os.rename(os.path.join(src_dir, item), os.path.join(target, item))
                    else:
                        os.makedirs(target, exist_ok=True)
                        tar.extractall(target)
        else:
            # Use 7z for non-tar files
            list_proc = self.run(["7z", "l", "-ba", "-slt", source], capture_output=True, text=True)
            files = [line.split('=')[1].strip() for line in list_proc.stdout.splitlines() if line.startswith("Path =")][1:]
            top_level = {f.split(os.sep)[0] for f in files}

            if len(top_level) > 1:
                self.run(["7z", "x", source, f"-o{target}"])
            elif len(top_level) == 1:
                root_name = list(top_level)[0]
                # Check if the single top level item is a directory by looking for children
                is_dir = any(f != root_name and f.startswith(root_name) for f in files)
                
                if is_dir:
                    import tempfile
                    with tempfile.TemporaryDirectory() as tmp:
                        self.run(["7z", "x", source, f"-o{tmp}"])
                        os.makedirs(target, exist_ok=True)
                        src_dir = os.path.join(tmp, root_name)
                        for item in os.listdir(src_dir):
                            os.rename(os.path.join(src_dir, item), os.path.join(target, item))
                else:
                    self.run(["7z", "x", source, f"-o{target}"])

    #### Downloads

    def dl(self, target: Optional[str], source: str) -> str:
        if target is None:
            random_name = uuid.uuid4().hex
            target = os.path.join(os.getcwd(), random_name)
            self.delete_later.append(target)

        self.run(["curl", "-C", "-", "-o", target, source])
        return target


#### Metadata


def load_metadata(m: Manager) -> None:
    if os.path.exists(m._pkg_json_path):
        try:
            with open(m._pkg_json_path, "r") as f:
                data = json.load(f)
            metadata = MetadataSchema.from_dict(data)
            for name, pkg in m.packages.items():
                if name in metadata.versions:
                    pkg.cached_versions = metadata.versions[name]
            # Keep package_versions dict in sync for the decorator logic
            m.package_versions = {k: v.to_dict() for k, v in metadata.versions.items()}
            m.delete_later = metadata.delete_later
        except Exception:
            m.package_versions = {}
            m.delete_later = []
    else:
        m.package_versions = {}
        m.delete_later = []


def save_metadata(m: Manager) -> None:
    versions = {}
    for name, pkg in m.packages.items():
        versions[name] = pkg.cached_versions

    metadata = MetadataSchema(versions=versions, delete_later=m.delete_later)
    data = metadata.to_dict()

    try:
        with open(m._pkg_json_path, "w") as f:
            json.dump(data, f, indent=4)
    except Exception as e:
        print(f"Warning: failed to save version data: {e}", file=sys.stderr)


#### Commands


def run_install(
    m: Manager,
    *,
    packages: List[str],
    tags: Optional[List[str]] = None,
    force: bool = False,
) -> None:
    if not packages and not tags:
        print("Error: No packages or tags specified.", file=sys.stderr)
        return

    target_names = list(m.packages.keys()) if not packages and tags else packages

    for name in target_names:
        if name not in m.packages:
            print(f"Error: Package '{name}' is not defined.", file=sys.stderr)
            continue
        pkg = m.packages[name]
        if tags and not any(t in pkg.tags for t in tags):
            continue
        pkg.install(force=force)

    save_metadata(m)


def run_update(
    m: Manager, *, packages: List[str], tags: Optional[List[str]] = None
) -> None:
    if not packages and not tags:
        print("Error: No packages or tags specified.", file=sys.stderr)
        return

    target_names = list(m.packages.keys()) if not packages and tags else packages

    for name in target_names:
        if name not in m.packages:
            print(f"Error: Package '{name}' is not defined.", file=sys.stderr)
            continue
        pkg = m.packages[name]
        if tags and not any(t in pkg.tags for t in tags):
            continue
        new_version = pkg.get_current_version()
        if new_version is not None:
            old = pkg.cached_versions.cached
            pkg.cached_versions.cached = new_version
            print(
                f"Updated cached version for package '{name}': {old} -> {new_version}"
            )
        else:
            print(f"Package '{name}': no version information, skipping.")

    for name, pkg in m.packages.items():
        m.package_versions[name] = {
            "installed": pkg.cached_versions.installed,
            "cached": pkg.cached_versions.cached,
        }
    save_metadata(m)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run a config file with Manager exposed as 'm'"
    )
    parser.add_argument("--config", help="Path to the config file (e.g., config.py)")
    subparsers = parser.add_subparsers(dest="subcommand")

    parser_install = subparsers.add_parser("install", help="Install given packages")
    parser_install.add_argument(
        "packages",
        nargs="*",
        help="Names of packages to install (optional if using tags)",
    )
    parser_install.add_argument(
        "-t",
        "--tag",
        action="append",
        dest="tags",
        help="Filter by tag (may be specified multiple times)",
    )
    parser_install.add_argument(
        "-f",
        "--force",
        action="store_true",
        help="Force reinstall even if version unchanged",
    )

    parser_update = subparsers.add_parser(
        "update", help="Update cached versions of packages"
    )
    parser_update.add_argument(
        "packages",
        nargs="*",
        help="Names of packages to update (optional if using tags)",
    )
    parser_update.add_argument(
        "-t",
        "--tag",
        action="append",
        dest="tags",
        help="Filter by tag (may be specified multiple times)",
    )

    args = parser.parse_args()

    if args.config:
        m = Manager()
        sub_globals = {"m": m}
        try:
            with open(args.config, "r") as f:
                config_code = f.read()
            exec(config_code, sub_globals)
        except Exception as e:
            print(f"Error executing config file: {e}", file=sys.stderr)
            sys.exit(1)

        # Load metadata after config is executed so packages are registered
        load_metadata(m)

        if args.subcommand == "install":
            run_install(m, packages=args.packages, tags=args.tags, force=args.force)
        elif args.subcommand == "update":
            run_update(m, packages=args.packages, tags=args.tags)
        else:
            if args.subcommand is None:
                print("No subcommand specified.", file=sys.stderr)
            else:
                print(f"Unknown subcommand: {args.subcommand}", file=sys.stderr)
            sys.exit(1)
    else:
        print(
            "No config file provided. Use --config <file> to specify one.",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
