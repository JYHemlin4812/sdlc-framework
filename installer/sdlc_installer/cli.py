"""Command line (design §2). E1 only ships the entry point; commands arrive in E3 to E6."""
import argparse
import sys

from .errors import USAGE

COMMANDS = ('install', 'uninstall', 'verify', 'capture', 'restore', 'scan-fuites')


def main(argv=None):
    parser = argparse.ArgumentParser(prog='install.py', description='SDLC installer (Python, in progress).')
    parser.add_argument('command', choices=COMMANDS)
    args, _rest = parser.parse_known_args(argv)
    sys.stderr.write('%s: not implemented yet (step E1 ships the primitives only)\n' % args.command)
    return USAGE
