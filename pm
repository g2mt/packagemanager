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
from urllib.parse import urlparse
import shutil
import tempfile
import glob
from pathlib import Path
from typing import List, Optional, Callable, Dict
from dataclasses import dataclass, asdict
import stat  # added for chmod functionality

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
    delete_later: List[str]

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

ORIGINAL_WORKDIR = os.getcwd()
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
        version: Optional[Callable[["Package"], str] | str] = None,
        clean_before_install: bool = True,
    ) -> None:
        """Initialize Package.

        Args:
            func: A callable that will be invoked when the package is installed.
                  It receives the Package instance.
            name: The package name, used for directory lookup and metadata.
            tags: Optional list of tags for filtering packages.
            readable_name: Optional human-readable name; defaults to *name* if not provided.
            version: Optional version string or callable returning version string.
            clean_before_install: If True, and the package installation directory is not empty,
                                  the user will be prompted to remove all existing contents before
                                  calling the install function. Defaults to True.
        """
        self.func = func
        self.name = name
        self.tags: List[str] = tags if tags is not None else []
        self.readable_name = readable_name if readable_name is not None else name
        self.installing_version = None
        self.cached_versions = CachedVersionsSchema()
        self._version_expr = version  # value or callable
        self.clean_before_install = clean_before_install

    def install(self, force: bool) -> None:
        """Install the package, optionally forcing reinstallation if *force* is True."""
        if (
            not force
            and self.cached_versions.installed is not None
            and self.cached_versions.installed == self.cached_versions.cached
        ):
            return
        self.installing_version = self._get_current_version()
        assert m is not None
        package_dir = os.path.join(m.datadir, self.name)
        os.makedirs(package_dir, exist_ok=True)
        if (
            self.clean_before_install
            and self.cached_versions.installed is not None
            and len(os.listdir(package_dir)) > 0
            and m._interactive_ask("Clean before install", package_dir)
        ):
            m.log(f"Cleaning {package_dir}")
            for entry in os.listdir(package_dir):
                full_path = os.path.join(package_dir, entry)
                if os.path.isdir(full_path):
                    shutil.rmtree(full_path)
                else:
                    os.remove(full_path)
        try:
            m.log(f"cd {package_dir}")
            os.chdir(package_dir)
            self.func(self)
        finally:
            os.chdir(ORIGINAL_WORKDIR)
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
    datadir: str

    def __init__(self) -> None:
        self._pkg_json_path = os.path.join(CONFIG_PATH, "pkg.json")
        self._packages: Dict[str, Package] = {}
        self._package_versions: Dict[str, dict] = {}
        self._delete_later: List[str] = []
        self._interactive: bool = False
        self._skip_downloads: bool = False
        self.datadir = CONFIG_PATH

    ### Public methods

    #### Definitions

    def package(self, **kwargs) -> Callable:
        """Register a decorator for a package with given *kwargs* (name, tags, version). See [Package.__init__]. The inner function will be called with the package on install."""

        def decorator(func: Callable[[Package], None]) -> Callable[[Package], None]:
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

    def warn(self, s: str):
        """Print *s* to stdout in yellow."""
        print(f"{ANSI_YELLOW}{s}{ANSI_RESET}")

    def _interactive_ask(
        self, action: str, arg: Optional[str | list[str]] = None, *, always: bool = False
    ) -> bool:
        if not always and not self._interactive:
            return True
        prompt = f"{ANSI_YELLOW}{action}:{ANSI_RESET}"
        if arg is not None:
            if isinstance(arg, list):
                for item in arg:
                    prompt += "\n- "
                    prompt += item
                prompt += "\n"
            elif "\n" in arg:
                prompt += f"\n{arg}\n"
            else:
                prompt += f" {arg} "
        else:
            prompt += " "
        prompt += f"{ANSI_YELLOW}[y/N]{ANSI_RESET} "
        if input(prompt).lower() not in ("y", "yes"):
            return False
        return True

    #### Process execution

    def run(
        self, args: list, *, interactive: bool = True, **kwargs
    ) -> subprocess.CompletedProcess:
        """Execute `*args`, `**kwargs` via `subprocess.run` and return the CompletedProcess."""
        if interactive and not self._interactive_ask("Run command", " ".join(args)):
            raise RuntimeError("User interrupted run command")
        self.log(" ".join(args))
        return subprocess.run(args, **kwargs)

    def bash(self, bash_source: str, **kwargs) -> bytes:
        """Executes bash with the *bash_source*, returning the stdout. The *bash_source* is automatically dedented before the call."""
        bash_source = textwrap.dedent(bash_source).strip()
        if not self._interactive_ask("Run bash", bash_source):
            raise RuntimeError("User interrupted run command")
        self.log(bash_source)
        return subprocess.check_output(["bash", "-c", bash_source], **kwargs)

    #### Utils

    def install_appimage(self, pkg: Package, source: str) -> None:
        """
        Install an AppImage package from *source* file. The AppImage is extracted and a .desktop entry is created.
        """
        source = os.path.realpath(source)

        if os.path.isfile(source):
            current_mode = os.stat(source).st_mode
            os.chmod(source, current_mode | stat.S_IXUSR)
        else:
            raise FileNotFoundError(source)

        desktop_dir = os.path.expanduser("~/.local/share/applications")
        icon_dir = os.path.expanduser("~/.local/share/icons")
        desktop_path = os.path.join(desktop_dir, f"{pkg.name}.desktop")

        os.makedirs(desktop_dir, exist_ok=True)
        os.makedirs(icon_dir, exist_ok=True)

        with tempfile.TemporaryDirectory() as tmp:
            self.run(
                [source, "--appimage-extract"],
                cwd=tmp,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

            squashfs_root = os.path.join(tmp, "squashfs-root")
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

            if len(icons) == 1:
                icon_src = icons[0]
            else:
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

            desktop_content = textwrap.dedent(f"""
                [Desktop Entry]
                Name={pkg.readable_name}
                StartupWMClass={pkg.readable_name}
                Exec="{source}"
                Icon={icon_dst}
                Type=Application
                Terminal=false""")
            with open(desktop_path, "w") as f:
                f.write(desktop_content)

    #### Filesystem operations

    def link(self, target: str, source: str):
        """Create a symbolic link from *source* file to *target* file."""
        target_path = Path(target)
        source_path = Path(source).absolute()

        if target_path.is_symlink():
            if target_path.resolve() == source_path:
                return
            else:
                if self._interactive_ask(
                    "Remove existing link", str(target_path), always=True
                ):
                    target_path.unlink(missing_ok=True)
                else:
                    raise RuntimeError(
                        f"Link {target} already exists but points to {target_path.resolve()} instead of {source_path}"
                    )

        if target_path.exists():
            raise RuntimeError(
                f"Cannot create link: {target} already exists and is not a symlink"
            )

        os.symlink(source_path, target_path)

    def link_in_dir(
        self, target: str, source_dir: str, *, executables_only: bool = False
    ):
        """Create symlinks for all files in *source_dir* into *target* directory.

        If executables_only is True, only symlink entries that are executable
        (checked via os.access with os.X_OK).
        """
        os.makedirs(target, exist_ok=True)
        for entry in os.listdir(source_dir):
            source_path = os.path.join(source_dir, entry)
            if executables_only and not os.access(source_path, os.X_OK):
                continue
            target_path = os.path.join(target, entry)
            self.link(target_path, source_path)

    #### Extract

    def _extract_tar(self, target: str, source: str):
        target = os.path.normpath(target)
        with tarfile.open(source) as tar:
            members = tar.getmembers()
            top_level: Optional[str] = None
            top_level_is_dir = False
            for m in tar.getmembers():
                m_parts = Path(m.name).parts
                if len(m_parts) == 0:
                    continue
                m_top_level = m_parts[0]
                if top_level is None:
                    top_level = m_top_level
                    if m.isdir():
                        # is dir when the top level directory itself is the name
                        top_level_is_dir = len(m_parts) == 1
                    else:
                        # always dir if member is a non directory
                        top_level_is_dir = True
                elif top_level != m_top_level:  # multiple top level paths
                    top_level = None
                    break

            if top_level is None:
                # multiple top-level entries exist
                os.makedirs(target, exist_ok=True)
                tar.extractall(target)
            elif top_level_is_dir:
                with tempfile.TemporaryDirectory() as tmp:
                    tar.extractall(tmp)
                    os.makedirs(target, exist_ok=True)
                    tmp_top_level = os.path.join(tmp, top_level)
                    for item in os.listdir(tmp_top_level):
                        # manually move toplevel/* to target/*
                        shutil.move(os.path.join(tmp_top_level, item), os.path.join(target, item))
            else:
                os.makedirs(target, exist_ok=True)
                tar.extractall(target)

    def _extract_nontar(self, target: str, source: str):
        target = os.path.normpath(target)
        with tempfile.TemporaryDirectory() as tmp:
            self.run(["7z", "x", source, f"-o{tmp}"])
            items = os.listdir(tmp)

            tmp_top_level = os.path.join(tmp, items[0])
            if len(items) == 1 and os.path.isdir(tmp_top_level):
                # Single top-level directory: move it to target
                os.makedirs(target, exist_ok=True)
                for item in os.listdir(tmp_top_level):
                    # manually move toplevel/* to target/*
                    shutil.move(os.path.join(tmp_top_level, item), os.path.join(target, item))
            else:
                # Multiple top-level entries or a single file: extract into target
                os.makedirs(target, exist_ok=True)
                for item in items:
                    shutil.move(os.path.join(tmp, item), os.path.join(target, item))

    def extract(self, target: str, source: str) -> None:
        """Extract *source* archive into *target* directory using tarlib and falling back to the 7z command."""
        if not self._interactive_ask("Extract", f"{source} to {target}"):
            return None
        if tarfile.is_tarfile(source):
            return self._extract_tar(target, source)
        else:
            return self._extract_nontar(target, source)

    #### Downloads

    def github_ver(
        self,
        repo: str,
        re_pattern: Optional[str] = None,
        api_url: str = "https://api.github.com",
    ) -> str:
        """Return the latest release version tag from *repo* (optionally matching *re_pattern*, returning the 1st matched regex group if provided)."""
        data = json.loads(self.dl_text(f"{api_url}/repos/{repo}/releases/latest"))
        tag = data.get("tag_name", "")
        if re_pattern is None:
            return tag
        match = re.search(re_pattern, tag)
        if match and match.groups():
            return match.group(1)
        raise RuntimeError(f"tag {tag} does not match pattern /{re_pattern}/")

    def dl(
        self, target: Optional[str], source: str, *, delete_later: Optional[bool] = None
    ) -> str:
        """Download file from *source* URL to *target* file (or a temp file if *target* is None) and optionally mark for later deletion."""
        if target is None:
            # Attempt to extract filename from the source URL
            parsed = urlparse(source)
            filename = os.path.basename(parsed.path) or uuid.uuid4().hex
            target = os.path.join(os.getcwd(), filename)
            if delete_later is None:
                delete_later = True

        if self._skip_downloads:
            return target

        self.run(["curl", "-C", "-", "-L", "-o", target, source])
        if delete_later:
            self._delete_later.append(target)
        return target

    def dl_git(self, target: str, source: str) -> None:
        """Clone or update git repository in *source* URL into *target* directory and pull to latest commit."""
        if not os.path.exists(target):
            self.run(
                ["git", "clone", "--filter=tree:0", source, target], interactive=False
            )
            return
        if not os.path.isdir(os.path.join(target, ".git")):
            raise RuntimeError(f"Target {target} exists but is not a git repository")
        branch_proc = self.run(
            ["git", "-C", target, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            interactive=False,
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
                interactive=False,
            )
            newest_tag = newest_tag_proc.stdout.strip().splitlines()
            newest_tag = newest_tag[0] if newest_tag else None
            current_tag_proc = self.run(
                ["git", "-C", target, "describe", "--tags", "--exact-match", "HEAD"],
                capture_output=True,
                text=True,
                interactive=False,
            )
            current_tag = (
                current_tag_proc.stdout.strip()
                if current_tag_proc.returncode == 0
                else None
            )
            if newest_tag is not None and current_tag != newest_tag:
                if current_tag is not None:
                    self.warn(
                        f"current checked out tag {current_tag} is not the newest tag {newest_tag} for repo {source}"
                    )
                else:
                    self.warn(
                        f"HEAD not at a tag; newest tag is {newest_tag} for repo {source}"
                    )

    def dl_text(self, source: str) -> str:
        """Performs an HTTP GET request to *source* URL, returning the result of the HTTP request"""
        with urllib.request.urlopen(source) as response:
            return response.read().decode()


m = Manager()

#### Metadata


def load_metadata() -> None:
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


def save_metadata() -> None:
    versions = {}
    for name, pkg in m._packages.items():
        versions[name] = pkg.cached_versions

    metadata = MetadataSchema(versions=versions, delete_later=m._delete_later)
    data = metadata.to_dict()

    with open(m._pkg_json_path, "w") as f:
        json.dump(data, f, indent=4)


#### Commands


def run_install(
    *,
    packages: List[str],
    tags: Optional[List[str]] = None,
    force: bool = False,
    interactive: bool = False,
) -> None:
    if not packages and not tags:
        print("Error: No packages or tags specified.", file=sys.stderr)
        return

    target_names = list(m._packages.keys()) if not packages and tags else packages
    m._interactive = interactive

    for name in target_names:
        if name not in m._packages:
            print(f"Error: Package '{name}' is not defined.", file=sys.stderr)
            continue
        pkg = m._packages[name]
        if tags and not any(t in pkg.tags for t in tags):
            continue
        pkg.install(force=force)

    save_metadata()


def run_update(*, packages: List[str], tags: Optional[List[str]] = None) -> None:
    target_names = packages if packages else m._packages.keys()

    for name in target_names:
        try:
            pkg = m._packages[name]
        except KeyError:
            m.warn(f"Package '{name}' is not defined.")
            continue
        if tags and not any(t in pkg.tags for t in tags):
            continue
        new_version = pkg._get_current_version()
        if new_version is not None:
            old = pkg.cached_versions.cached
            pkg.cached_versions.cached = new_version
            m.log(
                f"Updated cached version for package '{name}': {old} -> {new_version}"
            )
        else:
            m.warn(f"Package '{name}': no version information, skipping.")

    save_metadata()


def run_list(names_only: bool = False) -> None:
    for name in sorted(m._packages.keys()):
        pkg = m._packages[name]
        if names_only:
            print(name)
            continue
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
        if hasattr(cls, "__annotations__"):
            for attr_name, attr_type in cls.__annotations__.items():
                if attr_name.startswith("_"):
                    continue
                if hasattr(attr_type, "__origin__"):
                    # generic alias e.g. List[str], Optional[str], Callable
                    type_str = str(attr_type)
                else:
                    # simple type (str, int, custom class, etc.)
                    type_str = getattr(attr_type, "__name__", str(attr_type))
                lines.append(f"  {attr_name}: {type_str}")
        for name, method in inspect.getmembers(cls, predicate=inspect.isfunction):
            if method.__module__ != __name__:
                continue
            if name.startswith("_"):  # skip private methods
                continue
            sig_str = str(inspect.signature(method))
            lines.append(f"  {name}{sig_str}")
            if method.__doc__:
                doc_lines = method.__doc__.splitlines()
                for dl in doc_lines:
                    lines.append("    " + dl)
        lines.append("")
    print("\n".join(lines))


def run_clean() -> None:
    """Delete all files from delete_later list after prompting user."""
    if not m._delete_later:
        m.warn("No files to clean.")
        return
    if not m._interactive_ask("Delete", m._delete_later, always=True):
        return
    for path in m._delete_later:
        if os.path.exists(path):
            os.remove(path)
            m.log(f"Deleted {path}")
    m._delete_later.clear()
    save_metadata()


def run_edit(config_path: str) -> None:
    """Open the config file in $EDITOR."""
    editor = os.environ.get("EDITOR", "vi")
    subprocess.call([editor, config_path])


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run a config file with Manager exposed as 'm'"
    )
    parser.add_argument(
        "--config",
        help="Path to the config file (e.g., config.py)",
        default=os.path.join(CONFIG_PATH, "config.py"),
    )
    parser.add_argument(
        "--skip-downloads",
        action="store_true",
        help="Skip any actual downloads (useful for testing)",
    )
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
    parser_install.add_argument(
        "-i",
        "--interactive",
        action="store_true",
        help="Prompt before executing any process during install",
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
    parser_list.add_argument(
        "--names",
        action="store_true",
        help="Print only package names, without any formatting",
    )

    parser_docs = subparsers.add_parser(
        "docs", help="Show documentation for Package and Manager classes"
    )

    parser_clean = subparsers.add_parser(
        "clean", help="Delete all files marked for deletion (in delete_later)"
    )

    parser_edit = subparsers.add_parser("edit", help="Open the config file in $EDITOR")

    args = parser.parse_args()

    # Handle subcommands not requiring a config file.
    if args.subcommand == "docs":
        return run_docs()
    elif args.subcommand == "edit":
        return run_edit(args.config)

    if args.config:
        m._skip_downloads = args.skip_downloads
        sub_globals = {"m": m}

        with open(args.config, "r") as f:
            config_code = f.read()
        exec(config_code, sub_globals)

        # Load metadata after config is executed so packages are registered
        load_metadata()

        if args.subcommand == "install":
            run_install(
                packages=args.packages,
                tags=args.tags,
                force=args.force,
                interactive=args.interactive,
            )
        elif args.subcommand == "update":
            run_update(packages=args.packages, tags=args.tags)
        elif args.subcommand == "list":
            run_list(names_only=args.names)
        elif args.subcommand == "clean":
            run_clean()
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
