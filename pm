#!/usr/bin/env python3

import argparse
import sys
from typing import List, Optional, Callable, Dict


class Package:
    def __init__(self, name: str, func: Callable[[], None], tags: Optional[List[str]] = None) -> None:
        self.name = name
        self.func = func
        self.tags: List[str] = tags if tags is not None else []

    def run(self) -> None:
        self.func()


class Manager:
    def __init__(self) -> None:
        self.packages: Dict[str, Package] = {}

    def package(self, name: str, tags: Optional[List[str]] = None) -> Callable:
        def decorator(func: Callable[[], None]) -> Callable[[], None]:
            pkg = Package(name, func, tags)
            self.packages[name] = pkg
            return func
        return decorator

    def run_install(self, package_names: List[str], tags: Optional[List[str]] = None) -> None:
        if not package_names and not tags:
            print("Error: No packages or tags specified.", file=sys.stderr)
            return
        if package_names:
            for name in package_names:
                if name not in self.packages:
                    print(f"Error: Package '{name}' is not defined.", file=sys.stderr)
                    continue
                pkg = self.packages[name]
                if tags and not any(t in pkg.tags for t in tags):
                    continue
                pkg.run()
        else:
            for name, pkg in self.packages.items():
                if any(t in pkg.tags for t in tags):
                    pkg.run()


def main() -> None:
    parser = argparse.ArgumentParser(description="Run a config file with Manager exposed as 'm'")
    parser.add_argument("--config", help="Path to the config file (e.g., config.py)")
    subparsers = parser.add_subparsers(dest='subcommand')
    parser_install = subparsers.add_parser('install', help='Install given packages')
    parser_install.add_argument('packages', nargs='*',
                                help='Names of packages to install (optional if using tags)')
    parser_install.add_argument('-t', '--tag', action='append', dest='tags',
                                help='Filter by tag (may be specified multiple times)')

    args = parser.parse_args()

    if args.config:
        sub_globals = {"m": Manager()}
        try:
            with open(args.config, "r") as f:
                config_code = f.read()
            exec(config_code, sub_globals)
            m: Manager = sub_globals["m"]
        except Exception as e:
            print(f"Error executing config file: {e}", file=sys.stderr)
            sys.exit(1)
        if args.subcommand == "install":
            m.run_install(args.packages, args.tags)
    else:
        print("No config file provided. Use --config <file> to specify one.", file=sys.stderr)


if __name__ == "__main__":
    main()
