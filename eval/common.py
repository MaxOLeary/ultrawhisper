"""Bits shared by the eval scripts: paths and the tiny flag parser."""
import json, os, sys

CONFIG = os.path.expanduser("~/.config/ultrawhisper")
REC = os.path.expanduser("~/Documents/superwhisper/recordings")

def opt(flag, default, cast=str):
    """Value after `flag` on the command line, cast; `default` if absent."""
    return cast(sys.argv[sys.argv.index(flag) + 1]) if flag in sys.argv else default

def read_jsonl(path):
    return [json.loads(l) for l in open(path)]
