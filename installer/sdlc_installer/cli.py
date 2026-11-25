"""Command line (design §2). E3: install and verify; E4: uninstall; the other commands arrive in E5 and E6."""
import argparse
import os
import sys

from .errors import FAILED, USAGE, InstallerError

COMMANDS = ('install', 'uninstall', 'verify', 'capture', 'restore', 'scan-fuites')
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _default_live():
    return os.path.join(os.path.expanduser('~'), '.claude')


def _parser():
    parser = argparse.ArgumentParser(prog='install.py', description='SDLC installer (Python).')
    sub = parser.add_subparsers(dest='command', metavar='command')
    sub.required = True
    p = sub.add_parser('install', help='deploy the SDLC domain into the live root')
    p.add_argument('--source', default=os.path.join(REPO, 'claude'), help='source claude/ folder (default: repo/claude)')
    p.add_argument('--live', default=None, help='live root (default: ~/.claude)')
    p.add_argument('--force', action='store_true', help='reinstall even if the source is unchanged')
    p.add_argument('--dry-run', action='store_true', help='show what would be deployed, write nothing')
    p.add_argument('--no-backup', action='store_true', help='no backup of bundle files (unknown files are always backed up)')
    p.add_argument('--allow-dirty', action='store_true', help='deploy the working tree of a dirty source')
    v = sub.add_parser('verify', help='compare the live root with the committed HEAD (read-only)')
    v.add_argument('--ref', default=REPO, help='reference repository root (default: this repository)')
    v.add_argument('--live', default=None, help='live root (default: ~/.claude)')
    v.add_argument('--subdir', default='claude', help=argparse.SUPPRESS)
    v.add_argument('--quiet', action='store_true', help='print nothing, exit code only')
    u = sub.add_parser('uninstall', help='remove the bundle files from the live root')
    u.add_argument('--live', default=None, help='live root (default: ~/.claude)')
    u.add_argument('--ref', default=REPO, help='reference repository, for the Git history proof (default: this repository)')
    u.add_argument('--force', action='store_true', help='no confirmation prompt')
    u.add_argument('--discover', action='store_true', help='without a readable registry: heuristic discovery')
    u.add_argument('--remove-core', action='store_true', help='also remove the agents/**/sdlc-* agents')
    for name in COMMANDS:
        if name not in ('install', 'verify', 'uninstall'):
            sub.add_parser(name, add_help=False).add_argument('rest', nargs=argparse.REMAINDER)
    return parser


def _write(line):
    sys.stdout.write(line + '\n')


def main(argv=None):
    args = _parser().parse_args(argv)
    live = getattr(args, 'live', None)
    if live is None:
        live = _default_live()
    elif not live.strip():
        # E3-R1-04: an explicit empty value never falls back to the real ~/.claude.
        sys.stderr.write('  [ERR] --live is empty\n')
        return USAGE
    try:
        if args.command == 'install':
            from . import install
            opts = install.Options(args.source, live, args.force, args.dry_run, args.no_backup, args.allow_dirty)
            return install.run(opts, _write)
        if args.command == 'uninstall':
            from . import uninstall
            return uninstall.run(live, args.ref, args.force, args.discover, args.remove_core, _write)
        if args.command == 'verify':
            from . import verify
            res = verify.verify(args.ref, live, args.subdir)
            if not args.quiet:
                verify.report(res, _write)
            return res.code
    except InstallerError as exc:
        sys.stderr.write('  [ERR] %s\n' % exc)
        return exc.code
    except OSError as exc:
        sys.stderr.write('  [ERR] I/O error: %s\n' % exc)
        return FAILED
    sys.stderr.write('%s: not implemented yet (arrives in a later step)\n' % args.command)
    return USAGE
