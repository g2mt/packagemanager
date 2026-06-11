# pm

- This is a one-file package manager application for Python
- Prioritize short, simple code, with no required external dependencies
- When adding a new CLI argument, make sure to update the files in the `completions` folder.
- Use `raise RuntimeError(...)` instead of `print("Error: ...", file=sys.stderr)` for error conditions
