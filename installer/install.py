"""Single documented entry point (design §9). Disables bytecode BEFORE importing the package."""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from sdlc_installer.cli import main  # noqa: E402

if __name__ == '__main__':
    sys.exit(main())
