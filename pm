#!/usr/bin/env python3

import argparse
import json
import os
import sys
from typing import List, Optional, Callable, Dict

#### Schemas

#### Manager objects

class Package:
    def __init__(self, func: Callable[[], None], *, name: str, tags: Optional[List[str]] = None, version=None) -> None:
        self.func = func
        self.name = name
        self.tags: List[str] = tags if tags is not None else []
        self._version_expr = version             # value or callable
        self.cached_versions: Dict[str, Optional[str]] = {"installed": None, "cached": None}

    def install(self, force: bool) -> None:
        if not force and self.cached_versions["installed"] == self.cached_versions["cached"]:
            return
        self.func()
        ver = self.get_current_version()
        if ver is not None:
            self.cached_versions["installed"] = ver
            self.cached_versions["cached"] = ver

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
        self._load_version_data()

    ### Version data

    def _load_version_data(self) -> None:
        if os.path.exists(self._pkg_json_path):
            try:
                with open(self._pkg_json_path, 'r') as f:
                    data = json.load(f)
                self.package_versions = data.get("versions", {})
            except Exception:
                self.package_versions = {}
        else:
            self.package_versions = {}

    def _load_package_versions(self, pkg: Package) -> None:
        data = self.package_versions.get(pkg.name)
        if isinstance(data, dict):
            pkg.cached_versions["installed"] = data.get("installed")
            pkg.cached_versions["cached"] = data.get("cached")

    ### Public methods

    #### Packaging

    def package(self, **kwargs) -> Callable:
        def decorator(func: Callable[[], None]) -> Callable[[], None]:
            pkg = Package(func, **kwargs)
            self.packages[pkg.name] = pkg
            self._load_package_versions(pkg)
            return func
        return decorator

    #### Downloads


def save_versions(m: Manager) -> None:
    versions = {}
    for name, pkg in m.packages.items():
        versions[name] = {
            "installed": pkg.cached_versions.get("installed"),
            "cached": pkg.cached_versions.get("cached"),
        }
    data = {"versions": versions}
    try:
        with open(m._pkg_json_path, 'w') as f:
            json.dump(data, f, indent=4)
    except Exception as e:
        print(f"Warning: failed to save version data: {e}", file=sys.stderr)


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

    save_versions(m)


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
            old = pkg.cached_versions.get("cached")
            pkg.cached_versions["cached"] = new_version
            print(f"Updated cached version for package '{name}': {old} -> {new_version}")
        else:
            print(f"Package '{name}': no version information, skipping.")

    for name, pkg in m.packages.items():
        m.package_versions[name] = {
            "installed": pkg.cached_versions.get("installed"),
            "cached": pkg.cached_versions.get("cached"),
        }
    save_versions(m)


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
