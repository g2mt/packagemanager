#!/usr/bin/env python3

import argparse
import sys
from typing import List, Optional, Callable, Dict


class Package:
    def __init__(self, func: Callable[[], None], *, name: str, tags: Optional[List[str]] = None) -> None:
        self.func = func
        self.name = name
        self.tags: List[str] = tags if tags is not None else []

    def run(self) -> None:
        self.func()


class Manager:
    def __init__(self) -> None:
        self.packages: Dict[str, Package] = {}

    def package(self, **kwargs) -> Callable:
        def decorator(func: Callable[[], None]) -> Callable[[], None]:
            pkg = Package(func, **kwargs)
            self.packages[pkg.name] = pkg
            return func
        return decorator

def run_install(m: Manager, *, packages: List[str], tags: Optional[List[str]] = None) -> None:
    if not packages and not tags:
        print("Error: No packages or tags specified.", file=sys.stderr)
        return
    for name in packages:
        if name not in m.packages:
            print(f"Error: Package '{name}' is not defined.", file=sys.stderr)
            continue
        pkg = m.packages[name]
        if tags and not any(t in pkg.tags for t in tags):
            continue
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
            run_install(m, packages=args.packages, tags=args.tags)
    else:
        print("No config file provided. Use --config <file> to specify one.", file=sys.stderr)


if __name__ == "__main__":
    main()
