#!/usr/bin/env python3

import argparse
import sys

class Manager:
    def run(self):
        pass

def main():
    parser = argparse.ArgumentParser(description="Run a config file with Manager exposed as 'm'")
    parser.add_argument("--config", help="Path to the config file (e.g., config.py)")
    args = parser.parse_args()

    if args.config:
        sub_globals = {"m": Manager()}
        try:
            with open(args.config, "r") as f:
                config_code = f.read()
            exec(config_code, sub_globals)
            m.run()
        except Exception as e:
            print(f"Error executing config file: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        print("No config file provided. Use --config <file> to specify one.", file=sys.stderr)

if __name__ == "__main__":
    main()
