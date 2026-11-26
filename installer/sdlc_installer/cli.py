"""Command line (design §2). E3: install and verify; E4: uninstall; E5: capture and restore; E6: scan-fuites."""
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
    c = sub.add_parser('capture', help='propose the live changes to the reference and commit them')
    _sync_args(c)
    c.add_argument('--conflict-log', default=None, help='append-only LWW log (default: <live>/conflicts.log)')
    c.add_argument('--lww', action='store_true', help='resolve modified-both (logged); the reference wins by default')
    c.add_argument('--provenance', choices=('ref', 'live'), default='ref', help='LWW winner (with --lww; default: ref)')
    c.add_argument('--adopt', action='store_true', help='first run: adopt the current state despite a divergence')
    c.add_argument('--dry-run', action='store_true', help='show what would be captured, write nothing')
    r = sub.add_parser('restore', help='make the live root match the committed reference')
    _sync_args(r)
    r.add_argument('--force-restore', action='store_true', help='overwrite a live-only modification (backed up)')
    r.add_argument('--dry-run', action='store_true', help='show what would be restored, write nothing')
    s = sub.add_parser('scan-fuites', help='read-only leak scan of the repository; writes a report')
    s.add_argument('--repo-root', default=REPO, help='repository to scan (default: this repository)')
    s.add_argument('--motifs-path', default=None, help='level-2 patterns (default: <repo>/SDLC_PM/scan-fuites-motifs.txt)')
    s.add_argument('--report-path', default=None,
                   help='report file (default: <repo>/SDLC_PM/SP6-productisation/rapport-scan-fuites-<date>.md)')
    return parser


def _sync_args(p):
    p.add_argument('--ref', default=REPO, help='reference repository root (default: this repository)')
    p.add_argument('--live', default=None, help='live root (default: ~/.claude)')
    p.add_argument('--subdir', default='claude', help=argparse.SUPPRESS)
    p.add_argument('--manifest-path', default=None, help='sync base (default: <live>/.sync-manifest.json)')
    p.add_argument('--allow-dirty', action='store_true', help=argparse.SUPPRESS)


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
        if args.command in ('capture', 'restore') and args.allow_dirty:
            # design §7: the dirty-tree rule of these commands has no opt-out.
            sys.stderr.write('  [ERR] --allow-dirty is not accepted by %s (design §7)\n' % args.command)
            return USAGE
        if args.command == 'capture':
            from . import capture
            opts = capture.Options(args.ref, live, args.subdir, args.manifest_path, args.conflict_log, args.lww,
                                   args.provenance, args.adopt, args.dry_run)
            return capture.run(opts, _write)
        if args.command == 'restore':
            from . import restore
            opts = restore.Options(args.ref, live, args.subdir, args.manifest_path, args.force_restore, args.dry_run)
            return restore.run(opts, _write)
        if args.command == 'scan-fuites':
            from . import scanfuites
            return scanfuites.run(args.repo_root, args.motifs_path, args.report_path, _write)
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
