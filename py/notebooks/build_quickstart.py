# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Author py/notebooks/quickstart.ipynb, then execute it so the committed file
carries real outputs for GitHub to render. Run from the repo root:

    python3 py/notebooks/build_quickstart.py

CI re-executes the notebook against an installed wheel; this script only
regenerates it after an API change."""
import os

import nbformat as nbf
from nbclient import NotebookClient

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(HERE, "quickstart.ipynb")

CELLS = [
    ("md", """# UniColor — Python quickstart

`unicolor` is a Cython extension over the UniColor C ABI, shipped as a
self-contained wheel: the native library travels inside the package, so
installing it needs neither Nim nor a compiler.

```
pip install lituus-unicolor
```

CI executes this notebook against the wheel the release actually publishes, so
an output below that stops matching fails the build."""),
    ("code", """import unicolor

unicolor.version(), unicolor.__version__"""),
    ("md", """## Colors

A `Color` is 4 float32 components plus a `SpaceTag`. Build one from a CSS
string or a space-specific factory; a bad build raises `ValueError` (the C
sentinel has `tag == unicolor.TAG_UNKNOWN`)."""),
    ("code", """red = unicolor.parse('#ff0000')
red.tag, red.components, red.alpha, red.format_css()"""),
    ("code", """unicolor.srgb(1.0, 0.0, 0.0).format_css(), unicolor.oklch(0.65, 0.18, 250.0).format_css()"""),
    ("code", """# format_css(legacy=True) emits sRGB hex; default is OKLCH.
red.format_css(legacy=True)"""),
    ("md", "## Conversion & gamut mapping"),
    ("code", """# convert() changes the space; gamut_map() maps an out-of-gamut color
# into a target space's realizable range.
(red.convert(unicolor.TAG_OKLCH).format_css(),
 unicolor.oklch(0.7, 0.3, 200.0).gamut_map(unicolor.TAG_SRGB).format_css(legacy=True))"""),
    ("md", """## Contrast & distance

`contrast` defaults to the WCAG 2.2 ratio; named metrics like `apca` are
supported. `distance` is a perceptual ΔE under a named metric."""),
    ("code", """(unicolor.contrast(unicolor.parse('#000000'), unicolor.parse('#ffffff')),
 unicolor.contrast(unicolor.parse('#000000'), unicolor.parse('#ffffff'), metric='apca'))"""),
    ("code", """unicolor.distance(unicolor.parse('#ff0000'), unicolor.parse('#00ff00'), 'deltaE_ok')"""),
    ("md", """## Themes

A `Theme` is a 3-layer token tree (primitives / semantics / components). Build
it from `(name, color|None, alias|None)` tuples: primitives carry a color,
semantics and components carry an alias."""),
    ("code", """t = unicolor.theme(
    [('surface', unicolor.srgb(1.0, 1.0, 1.0), None),
     ('text', unicolor.srgb(0.0, 0.0, 0.0), None)],
    [('text.primary', None, 'text')],
)
t.count, t.has_role('text.primary')"""),
    ("code", """print(t.resolve('text.primary').format_css())
print(t.export('css'))"""),
    ("md", """## Palettes

A `Palette` is an immutable color set. `color_at(i)` indexes the discrete
structures; `sample(t)` reads an ordered ramp at `t in [0,1]`. Both raise
`ValueError` when the structure does not support the operation or the index is
out of range."""),
    ("code", """p = unicolor.palette(
    unicolor.PAL_TAG_ORDERED,
    [unicolor.parse('#ff0000'), unicolor.parse('#00ff00'), unicolor.parse('#0055ff')],
    unicolor.PAL_INTENT_SEQUENTIAL,
)
len(p), p.color_at(1).format_css(), p.sample(0.5).format_css()"""),
    ("md", """## Import & validation

`import_theme` reconstructs a theme from a serialized source (JSON, CSS, ...);
`import_reported` returns the diagnostics without the target. `validate_theme`
/ `validate_palette` run every registered rule and return a scored report."""),
    ("code", """j = t.export('json')
t2 = unicolor.import_theme(j, 'json')
t2.count, t2.resolve('surface').tag"""),
    ("code", """rep = unicolor.validate_theme(t2)
rep.score, rep.worst, rep.rule_count"""),
    ("code", """rep.rule(0)"""),
    ("md", """## The C ABI underneath

The same entry points are reachable from anything that speaks C:

```c
const char *uc_version(void);
uc_color uc_parse(const char *s);
uc_color uc_convert(uc_color c, int target);
double uc_contrast(uc_color fg, uc_color bg);
uc_theme *uc_theme_make(uc_token *prim, size_t nprim, ...);
uc_validation *uc_validate_theme(uc_theme *t);
```

See `include/UniColor.h`, and the book for the full picture."""),
]


def main():
    nb = nbf.v4.new_notebook()
    nb.cells = [
        nbf.v4.new_markdown_cell(src) if kind == "md" else nbf.v4.new_code_cell(src)
        for kind, src in CELLS
    ]
    nb.metadata["kernelspec"] = {
        "display_name": "Python 3",
        "language": "python",
        "name": "python3",
    }
    # Execute from the repo root, never from py/: there, `import unicolor`
    # would resolve to the py/unicolor source tree instead of the installed
    # package, and the notebook would stop testing what it claims to test.
    NotebookClient(nb, timeout=120, kernel_name="python3",
                   resources={"metadata": {"path": ROOT}}).execute()
    with open(OUT, "w") as f:
        nbf.write(nb, f)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()