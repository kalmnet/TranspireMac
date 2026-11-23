"""Leave the original DSP intact and omit DSP recalculation from the editor VM."""
from pathlib import Path
import sys

script = Path(sys.argv[1])
prefix, marker, graphics = script.read_text().partition("@gfx")
before = "_sliderDirty ? (\n  ProcessSliders();\n  _sliderDirty = 0;\n);"
if not marker or graphics.count(before) != 1:
    raise ValueError("Unexpected Transpire graphics source")
graphics = graphics.replace(before, "_sliderDirty = 0;")
script.with_name("TranspireEditor.jsfx").write_text(prefix + marker + graphics)
