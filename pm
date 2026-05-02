#!/usr/bin/env python3

import argparse
import textwrap
import re
import json
import os
import subprocess
import tarfile
import sys
import uuid
import pydoc
import inspect
import urllib.request
import shutil
import tempfile
import glob
from pathlib import Path
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
ANSI_GRAY = "\033[90m"
ANSI_GREEN = "\033[92m"
ANSI_YELLOW = "\033[93m"

CONFIG_PATH = os.path.expanduser("~/.config/pm")

#### Manager objects


class Package:
    func: Callable[["Package"], None]
    name: str
    tags: List[str]
    readable_name: Optional[str]
    installing_version: Optional[str]
    cached_versions: CachedVersionsSchema

    def __init__(
        self,
        func: Callable[["Package"], None],
        *,
        name: str,
        tags: Optional[List[str]] = None,
        readable_name: Optional[str] = None,
        version: Optional[Callable[["Package"], str] | str] =None,
    ) -> None:
        """Initialize Package.

        Args:
            func: A callable that will be invoked when the package is installed.
                  It receives the Package instance.
            name: The package name, used for directory lookup and metadata.
            tags: Optional list of tags for filtering packages.
            readable_name: Optional human-readable name; defaults to *name* if not provided.
            version: Optional version string or callable returning version string.
        """
        self.func = func
        self.name = name
        self.tags: List[str] = tags if tags is not None else []
        self.readable_name = readable_name if readable_name is not None else name
        self.installing_version = None
        self.cached_versions = CachedVersionsSchema()
        self._version_expr = version  # value or callable

    def install(self, force: bool) -> None:
        """Install the package, optionally forcing reinstallation if *force* is True."""
        if (
            not force
            and self.cached_versions.installed is not None
            and self.cached_versions.installed == self.cached_versions.cached
        ):
            return
        old_cwd = os.getcwd()
        self.installing_version = self._get_current_version()
        try:
            os.chdir(os.path.join(CONFIG_PATH, self.name))
            self.func(self)
        finally:
            os.chdir(old_cwd)
        if self.installing_version is not None:
            self.cached_versions.installed = self.installing_version
            self.cached_versions.cached = self.installing_version

    def _get_current_version(self) -> Optional[str]:
        """Return the current version string by evaluating the version expression, or None."""
        if self._version_expr is None:
            return None
        if callable(self._version_expr):
            return self._version_expr(self) 
        return self._version_expr


class Manager:
    def __init__(self) -> None:
        self._pkg_json_path = os.path.join(CONFIG_PATH, "pkg.json")
        self._packages: Dict[str, Package] = {}
        self._package_versions: Dict[str, dict] = {}
        self._delete_later: List[str] = []

    ### Public methods

    #### Definitions

    def package(self, **kwargs) -> Callable:
        """Register a decorator for a package with given *kwargs* (name, tags, version). See [Package.__init__]. The inner function will be called with the package on install."""

        def decorator(func: Callable[[], None]) -> Callable[[], None]:
            pkg = Package(func, **kwargs)
            self._packages[pkg.name] = pkg
            data = self._package_versions.get(pkg.name)
            if isinstance(data, dict):
                pkg.cached_versions.installed = data.get("installed")
                pkg.cached_versions.cached = data.get("cached")
            return func

        return decorator

    #### Log

    def log(self, s: str):
        """Print *s* to stdout in gray."""
        print(f"{ANSI_GRAY}{s}{ANSI_RESET}")

    #### Process execution

    def run(self, args: list, **kwargs) -> subprocess.CompletedProcess:
        """Execute `*args`, `**kwargs` via `subprocess.run` and return the CompletedProcess."""
        self.log(" ".join(args))
        return subprocess.run(args, **kwargs)

    def bash(self, bash_source: str, **kwargs) -> bytes:
        """Executes bash with the *bash_source*, returning the stdout. The *bash_source* is automatically dedented before the call."""
        bash_source = textwrap.dedent(bash_source).strip()
        self.log(bash_source)
        return subprocess.check_output(["bash", "-c", bash_source], **kwargs)

    #### Utils

    def extract(self, target: str, source: str) -> None:
        """Extract *source* archive into *target* directory, handling tar or 7z."""
        if tarfile.is_tarfile(source):
            with tarfile.open(source) as tar:
                members = tar.getmembers()
                top_level = {m.name.split("/")[0] for m in members}

                if len(top_level) > 1:
                    os.makedirs(target, exist_ok=True)
                    tar.extractall(target)
                elif len(top_level) == 1:
                    root_name = list(top_level)[0]
                    root_member = next(
                        m for m in members if m.name.startswith(root_name)
                    )

                    if root_member.isdir():
                        import tempfile

                        with tempfile.TemporaryDirectory() as tmp:
                            tar.extractall(tmp)
                            os.makedirs(target, exist_ok=True)
                            src_dir = os.path.join(tmp, root_name)
                            for item in os.listdir(src_dir):
                                os.rename(
                                    os.path.join(src_dir, item),
                                    os.path.join(target, item),
                                )
                    else:
                        os.makedirs(target, exist_ok=True)
                        tar.extractall(target)
        else:
            # Use 7z for non-tar files
            list_proc = self.run(
                ["7z", "l", "-ba", "-slt", source], capture_output=True, text=True
            )
            files = [
                line.split("=")[1].strip()
                for line in list_proc.stdout.splitlines()
                if line.startswith("Path =")
            ][1:]
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
                            os.rename(
                                os.path.join(src_dir, item), os.path.join(target, item)
                            )
                else:
                    self.run(["7z", "x", source, f"-o{target}"])

    def install_appimage(self, pkg: Package, source: str) -> None:
        """
        Install an AppImage package from *source* file. The AppImage is extracted and a .desktop entry is created.
        """
        source = os.path.realpath(source)

        if not os.path.isfile(source):
            print(f"File not found: {source}", file=sys.stderr)
            return

        home = os.path.expanduser("~")
        desktop_dir = os.path.join(home, ".local", "share", "applications")
        icon_dir = os.path.join(home, ".local", "share", "icons")
        desktop_path = os.path.join(desktop_dir, f"{pkg.name}.desktop")

        os.makedirs(desktop_dir, exist_ok=True)
        os.makedirs(icon_dir, exist_ok=True)

        tmp_dir = tempfile.mkdtemp()
        try:
            self.run(
                [source, "--appimage-extract"],
                cwd=tmp_dir,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

            squashfs_root = os.path.join(tmp_dir, "squashfs-root")
            if not os.path.isdir(squashfs_root):
                raise RuntimeError(
                    "Extraction did not produce expected 'squashfs-root' directory"
                )

            # Find icon files (png or svg) in the root of the extracted tree
            icons = []
            for ext in ("*.png", "*.svg"):
                icons.extend(glob.glob(os.path.join(squashfs_root, ext)))

            if not icons:
                raise RuntimeError(
                    "No icon files (.png/.svg) found in the AppImage root"
                )

            print("Choose icon: ")
            for idx, icon in enumerate(icons, start=1):
                print(f" {idx}) {os.path.basename(icon)}")
            try:
                selection = int(input().strip())
                if selection < 1 or selection > len(icons):
                    raise ValueError
            except (ValueError, IndexError):
                self.log("Invalid selection, using first icon.")
                selection = 1

            icon_src = icons[selection - 1]
            icon_ext = os.path.splitext(icon_src)[1]  # e.g. .png
            icon_dst = os.path.join(icon_dir, f"{pkg.name}{icon_ext}")
            shutil.copy2(icon_src, icon_dst)

            desktop_content = f"""[Desktop Entry]
Name={pkg.readable_name}
StartupWMClass={pkg.readable_name}
Exec="{source}"
Icon={icon_dst}
Type=Application
Terminal=false
"""
            with open(desktop_path, "w") as f:
                f.write(desktop_content)
        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)

    #### Filesystem operations

    def link(self, target: str, source: str):
        """Create a symbolic link from *source* file to *target* file."""
        target_path = Path(target)
        source_path = Path(source).absolute()

        if target_path.is_symlink():
            if target_path.resolve() == source_path:
                return
            else:
                raise RuntimeError(
                    f"Link {target} already exists but points to {target_path.resolve()} instead of {source_path}"
                )

        if target_path.exists():
            raise RuntimeError(
                f"Cannot create link: {target} already exists and is not a symlink"
            )

        os.symlink(source_path, target_path)

    def link_in_dir(self, target: str, source_dir: str):
        """Create symlinks for all files in *source_dir* into *target* directory."""
        os.makedirs(target, exist_ok=True)
        for entry in os.listdir(source_dir):
            source_path = os.path.join(source_dir, entry)
            target_path = os.path.join(target, entry)
            self.link(target_path, source_path)

    #### Downloads

    def github_ver(
        self,
        repo: str,
        re_pattern: Optional[str] = None,
        api_url: str = "https://api.github.com",
    ) -> str:
        """Return the latest release version tag from *repo* (optionally matching *re_pattern*, returning the 1st matched regex group if provided)."""
        cmd = ["curl", "-sL", f"{api_url}/repos/{repo}/releases/latest"]
        proc = self.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            return ""

        data = json.loads(proc.stdout)
        tag = data.get("tag_name", "")
        if re_pattern is None:
            return tag
        match = re.search(re_pattern, tag)
        if match and match.groups():
            return match.group(1)
        raise RuntimeError(f"tag {tag} does not match pattern /{re_pattern}/")

    def dl(self, target: Optional[str], source: str) -> str:
        """Download file from *source* URL to *target* file (or a temp file if *target* is None)."""
        if target is None:
            random_name = uuid.uuid4().hex
            target = os.path.join(os.getcwd(), random_name)
            self._delete_later.append(target)

        self.run(["curl", "-C", "-", "-o", target, source])
        return target

    def dl_git(self, target: str, source: str) -> None:
        """Clone or update git repository in *source* URL into *target* directory and pull to latest commit."""
        if not os.path.exists(target):
            self.run(["git", "clone", "--filter=tree:0", source, target])
            return
        if not os.path.isdir(os.path.join(target, ".git")):
            raise RuntimeError(f"Target {target} exists but is not a git repository")
        branch_proc = self.run(
            ["git", "-C", target, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
        )
        current_branch = branch_proc.stdout.strip()
        if current_branch == "master":
            self.run(["git", "-C", target, "pull"])
        else:
            self.run(["git", "-C", target, "fetch", "--tags"])
            newest_tag_proc = self.run(
                [
                    "git",
                    "-C",
                    target,
                    "for-each-ref",
                    "--sort=-creatordate",
                    "--format",
                    "%(refname:short)",
                    "refs/tags",
                ],
                capture_output=True,
                text=True,
            )
            newest_tag = newest_tag_proc.stdout.strip().splitlines()
            newest_tag = newest_tag[0] if newest_tag else None
            current_tag_proc = self.run(
                ["git", "-C", target, "describe", "--tags", "--exact-match", "HEAD"],
                capture_output=True,
                text=True,
            )
            current_tag = (
                current_tag_proc.stdout.strip()
                if current_tag_proc.returncode == 0
                else None
            )
            if newest_tag is not None and current_tag != newest_tag:
                if current_tag is not None:
                    print(
                        f"Warning: current checked out tag {current_tag} is not the newest tag {newest_tag} for repo {source}",
                        file=sys.stderr,
                    )
                else:
                    print(
                        f"Warning: HEAD not at a tag; newest tag is {newest_tag} for repo {source}",
                        file=sys.stderr,
                    )

    def dl_text(self, source: str) -> str:
        """Performs an HTTP GET request to *source* URL, returning the result of the HTTP request"""
        with urllib.request.urlopen(source) as response:
            return response.read().decode()


#### Metadata


def load_metadata(m: Manager) -> None:
    if os.path.exists(m._pkg_json_path):
        try:
            with open(m._pkg_json_path, "r") as f:
                data = json.load(f)
            metadata = MetadataSchema.from_dict(data)
            for name, pkg in m._packages.items():
                if name in metadata.versions:
                    pkg.cached_versions = metadata.versions[name]
            # Keep package_versions dict in sync for the decorator logic
            m._package_versions = {k: v.to_dict() for k, v in metadata.versions.items()}
            m._delete_later = metadata.delete_later
        except Exception:
            m._package_versions = {}
            m._delete_later = []
    else:
        m._package_versions = {}
        m._delete_later = []


def save_metadata(m: Manager) -> None:
    versions = {}
    for name, pkg in m._packages.items():
        versions[name] = pkg.cached_versions

    metadata = MetadataSchema(versions=versions, delete_later=m._delete_later)
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

    target_names = list(m._packages.keys()) if not packages and tags else packages

    for name in target_names:
        if name not in m._packages:
            print(f"Error: Package '{name}' is not defined.", file=sys.stderr)
            continue
        pkg = m._packages[name]
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

    target_names = list(m._packages.keys()) if not packages and tags else packages

    for name in target_names:
        if name not in m._packages:
            print(f"Error: Package '{name}' is not defined.", file=sys.stderr)
            continue
        pkg = m._packages[name]
        if tags and not any(t in pkg.tags for t in tags):
            continue
        new_version = pkg._get_current_version()
        if new_version is not None:
            old = pkg.cached_versions.cached
            pkg.cached_versions.cached = new_version
            print(
                f"Updated cached version for package '{name}': {old} -> {new_version}"
            )
        else:
            print(f"Package '{name}': no version information, skipping.")

    for name, pkg in m._packages.items():
        m._package_versions[name] = {
            "installed": pkg.cached_versions.installed,
            "cached": pkg.cached_versions.cached,
        }
    save_metadata(m)


def run_list(m: Manager) -> None:
    for name in sorted(m._packages.keys()):
        pkg = m._packages[name]
        cached = pkg.cached_versions.cached
        installed = pkg.cached_versions.installed
        ver_display = cached if cached is not None else "N/A"
        use_color = False
        color_on = ""
        if installed is not None and cached is not None:
            if installed == cached:
                use_color = True
                color_on = ANSI_GREEN
            else:
                use_color = True
                color_on = ANSI_YELLOW
        colored = f"{color_on}{name} {ver_display}" + (ANSI_RESET if use_color else "")
        tag_part = ""
        if pkg.tags:
            tag_part = " [" + " ".join(sorted(pkg.tags)) + "]"
        line = f"{colored}{tag_part}"
        print(line)


def run_docs() -> None:
    classes = [Package, Manager]
    lines = []
    for cls in classes:
        lines.append(cls.__name__)
        if cls.__doc__:
            doc_lines = cls.__doc__.splitlines()
            for dl in doc_lines:
                lines.append("  " + dl)
        # Include non‑private field annotations
        if hasattr(cls, '__annotations__'):
            for attr_name, attr_type in cls.__annotations__.items():
                if attr_name.startswith('_'):
                    continue
                if hasattr(attr_type, '__origin__'):
                    # generic alias e.g. List[str], Optional[str], Callable
                    type_str = str(attr_type)
                else:
                    # simple type (str, int, custom class, etc.)
                    type_str = getattr(attr_type, '__name__', str(attr_type))
                lines.append(f"  {attr_name}: {type_str}")
        for name, method in inspect.getmembers(cls, predicate=inspect.isfunction):
            if method.__module__ != __name__:
                continue
            if name.startswith("_"): # skip private methods
                continue
            sig_str = str(inspect.signature(method))
            lines.append(f"  {name}{sig_str}")
            if method.__doc__:
                doc_lines = method.__doc__.splitlines()
                for dl in doc_lines:
                    lines.append("    " + dl)
        lines.append("")
    print("\n".join(lines))



def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run a config file with Manager exposed as 'm'"
    )
    parser.add_argument("--config", help="Path to the config file (e.g., config.py)",
                        default=os.path.join(CONFIG_PATH, "config.py"))
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

    parser_list = subparsers.add_parser("list", help="List all packages with versions")

    parser_docs = subparsers.add_parser(
        "docs", help="Show documentation for Package and Manager classes"
    )

    args = parser.parse_args()

    # Handle the docs subcommand without requiring a config file.
    if args.subcommand == "docs":
        return run_docs()

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
        elif args.subcommand == "list":
            run_list(m)
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
