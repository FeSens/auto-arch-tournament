"""pytest configuration for cores/v1 cocotb unit tests.

Adds this directory to sys.path so test_*.py modules can `import _helpers`
during pytest collection. Cocotb sets PYTHONPATH separately for the
simulator-side import.
"""
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
