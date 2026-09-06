#!/usr/bin/env python3
"""
Atlas Production Template — Standard PyYAML Configuration Reader
"""

import sys
import os
import json

# Add vendor dir to sys.path if present
vendor_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor")
if os.path.isdir(vendor_dir) and vendor_dir not in sys.path:
    sys.path.insert(0, vendor_dir)

try:
    import yaml
except ImportError:
    sys.stderr.write("[ERROR] PyYAML (python3-yaml) is required but not installed.\n")
    sys.stderr.write("Please install via: sudo apt-get install python3-yaml (or pip install pyyaml)\n")
    sys.exit(2)


def load_yaml_strict(filepath):
    if not os.path.exists(filepath):
        sys.stderr.write(f"[ERROR] File not found: {filepath}\n")
        sys.exit(2)
        
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception as e:
        sys.stderr.write(f"[ERROR] Failed to read {filepath}: {e}\n")
        sys.exit(2)
        
    try:
        data = yaml.safe_load(content)
        if data is None:
            return {}
        if not isinstance(data, dict):
            sys.stderr.write(f"[ERROR] Top-level YAML in {filepath} must be a mapping (dict), got {type(data).__name__}\n")
            sys.exit(2)
        return data
    except yaml.YAMLError as e:
        sys.stderr.write(f"[ERROR] Malformed YAML in {filepath}:\n{e}\n")
        sys.exit(2)


def get_nested(data, key_path):
    parts = key_path.split(".")
    curr = data
    for part in parts:
        if isinstance(curr, dict) and part in curr:
            curr = curr[part]
        elif isinstance(curr, list) and part.isdigit() and int(part) < len(curr):
            curr = curr[int(part)]
        else:
            return None
    return curr


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("Usage: yaml_parser.py <file.yml> [--json | <key> | --keys <key> | --has <key>]\n")
        sys.exit(2)
        
    filepath = sys.argv[1]
    data = load_yaml_strict(filepath)
    
    if len(sys.argv) == 2 or sys.argv[2] == "--json":
        print(json.dumps(data, indent=2))
        return
        
    action = sys.argv[2]
    
    if action == "--keys":
        key_path = sys.argv[3] if len(sys.argv) > 3 else ""
        target = get_nested(data, key_path) if key_path else data
        if isinstance(target, dict):
            for k in target.keys():
                print(k)
        elif isinstance(target, list):
            for idx in range(len(target)):
                print(idx)
        return
        
    if action == "--has":
        if len(sys.argv) < 4:
            sys.exit(2)
        val = get_nested(data, sys.argv[3])
        if val is not None:
            sys.exit(0)
        else:
            sys.exit(1)
            
    # Dot-separated query
    val = get_nested(data, action)
    if val is None:
        sys.exit(1)
    elif isinstance(val, (dict, list)):
        print(json.dumps(val))
    elif isinstance(val, bool):
        print("true" if val else "false")
    else:
        print(str(val))


if __name__ == "__main__":
    main()
