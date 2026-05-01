#!/usr/bin/env python3

import argparse
import json
import os
import sys
from typing import List, Optional, Callable, Dict
from dataclasses import dataclass, asdict

#### Schemas

@dataclass
class CachedVersionsSchema:
    installed: Optional[str] = None
    cached: Optional[str] = None

    @classmethod
    def from_dict(cls, data: dict) -> 'CachedVersionsSchema':
        return cls(
            installed=data.get("installed"),
            cached=data.get("cached")
        )

    def to_dict(self) -> dict:
        return asdict(self)

@dataclass
class MetadataSchema:
    versions: Dict[str, CachedVersionsSchema]

    @classmethod
    def from_dict(cls, data: dict) -> 'MetadataSchema':
        versions_data = data.get("versions", {})
        versions = {k: CachedVersionsSchema.from_dict(v) for k, v in versions_data.items()}
        return cls(versions=versions)

    def to_dict(self) -> dict:
        return {
            "versions": {k: v.to_dict() for k, v in self.versions.items()}
        }

#### Manager objects

class Package:
    def __init__(self, func: Callable[[], None], *, name: str, tags: Optional[List[str]] = None, version=None) -> None:
        self.func = func
        self.name = name
        self.tags: List[str] = tags if tags is not None else []
        self._version_expr = version             # value or callable
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
            return self._version_expr(self)          # call with the package object
        return self._version_expr


class Manager:
    def __init__(self) -> None:
        self.packages: Dict[str, Package] = {}
        self._pkg_json_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pkg.json')
        self.package_versions: Dict[str, dict] = {}

    ### Public methods

    #### Packaging

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

    #### Downloads

#### Metadata

def load_metadata(m: Manager) -> None:
    if os.path.exists(m._pkg_json_path):
        try:
            with open(m._pkg_json_path, 'r') as f:
                data = json.load(f)
            metadata = MetadataSchema.from_dict(data)
            for name, pkg in m.packages.items():
                if name in metadata.versions:
                    pkg.cached_versions = metadata.versions[name]
            # Keep package_versions dict in sync for the decorator logic
            m.package_versions = {k: v.to_dict() for k, v in metadata.versions.items()}
        except Exception:
            m.package_versions = {}
    else:
        m.package_versions = {}

def save_metadata(m: Manager) -> None:
    versions = {}
    for name, pkg in m.packages.items():
        versions[name] = pkg.cached_versions
    
    metadata = MetadataSchema(versions=versions)
    data = metadata.to_dict()
    
    try:
        with open(m._pkg_json_path, 'w') as f:
            json.dump(data, f, indent=4)
    except Exception as e:
        print(f"Warning: failed to save version data: {e}", file=sys.stderr)

#### Commands

def run_install(m: Manager, *, packages: List[str], tags: Optional[List[str]] = None, force: bool = False) -> None:
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


def run_update(m: Manager, *, packages: List[str], tags: Optional[List[str]] = None) -> None:
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
            print(f"Updated cached version for package '{name}': {old} -> {new_version}")
        else:
            print(f"Package '{name}': no version information, skipping.")

    for name, pkg in m.packages.items():
        m.package_versions[name] = {
            "installed": pkg.cached_versions.installed,
            "cached": pkg.cached_versions.cached,
        }
    save_metadata(m)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run a config file with Manager exposed as 'm'")
    parser.add_argument("--config", help="Path to the config file (e.g., config.py)")
    subparsers = parser.add_subparsers(dest='subcommand')

    parser_install = subparsers.add_parser('install', help='Install given packages')
    parser_install.add_argument('packages', nargs='*',
                                help='Names of packages to install (optional if using tags)')
    parser_install.add_argument('-t', '--tag', action='append', dest='tags',
                                help='Filter by tag (may be specified multiple times)')
    parser_install.add_argument('-f', '--force', action='store_true',
                                help='Force reinstall even if version unchanged')

    parser_update = subparsers.add_parser('update', help='Update cached versions of packages')
    parser_update.add_argument('packages', nargs='*',
                                help='Names of packages to update (optional if using tags)')
    parser_update.add_argument('-t', '--tag', action='append', dest='tags',
                                help='Filter by tag (may be specified multiple times)')

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
        print("No config file provided. Use --config <file> to specify one.", file=sys.stderr)


if __name__ == "__main__":
    main()
