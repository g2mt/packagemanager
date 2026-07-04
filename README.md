a minimal package manager for managing local user applications.

## Usage

```sh
pm install <package>   # Install a package (and its dependencies)
pm update <package>    # Refresh cached version info
pm list                # List all packages with versions
pm uninstall <package> # Remove installed files
pm list-files <pkg>    # Show installed files for a package
pm clean               # Delete temp downloads
pm docs                # Show API documentation
pm edit                # Open config in $EDITOR
```

## How it works

Packages are defined in `~/.config/pm/config.py` using the `@m.package()` decorator.

Built-in packages:
- **pm**: links the `pm` script to `~/.local/bin/`
- **pm-completions**: installs shell completions for bash/fish

By default, all packages are installed into `{m.datadir}/{package name}`.
You may set `m.datadir` in the config script to any other directory.

## Quick start

Install with:

```sh
./pm install pm
```

Place your package source into `~/.config/pm/config.py`:

```py
@m.package(name="hello", version="1.0", tags=["dev"])
def install_hello(pkg):
    m.dl("hello.tar.gz", "https://example.com/hello.tar.gz")
    m.extract("hello.tar.gz", ".")
    m.link_in_dir(os.path.expanduser("~/.local/bin"), "hello/bin", executables_only=True)
```

## License

MIT License.

AI-Disclosure: ai-generated.

