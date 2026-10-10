# CORE-ET Micro-Architecture Document

Micro-architecture document for the open-sourced CORE-ET RTL in [`rtl/`](../../rtl/).

Where this document and the legacy documents in [`docs/uarch/`](../uarch/) (Markdown copies in [`docs/uarch_md/`](../uarch_md/)) disagree, the RTL is the source of truth.

**Status**

| # | Chapter | State |
|---|---|---|
| 1 | ET-SoC-1 Overview | Written, except Memory Map, which is a heading only. Describes the ET-SoC-1 chip; the RTL in this repository is one Neighborhood behind an AXI port, so the scope of this chapter is under review |
| 2 | ET-Minion Core | Core Overview and Front End written; Integer Pipeline, Data Cache and VPU are headings only |
| 3 | Neighborhood | Overview, Neighborhood Instruction Cache and Front End – I-Cache Interface written; L0 Micro-Cache, L1 Instruction Cache, Page-Table Walker, Memory Request and Response Path, Tensor Support and Synchronization are headings only |

## Contents

| Path | Purpose |
|---|---|
| `core-et-uarch.adoc` | Main document (Asciidoctor, book doctype): front matter and chapter includes |
| `chapters/` | One AsciiDoc file per chapter |
| `images/<chapter>/` | Figures used by that chapter. A figure named `*.drawio.png` carries its draw.io XML inside the PNG and opens in draw.io as an editable diagram |
| `images/<chapter>/src/` | WaveJSON sources of that chapter's timing diagrams, `td-*.json5` |
| `themes/uarch-theme.yml` | PDF theme |
| `docinfo.html` | HTML style (centered figure captions) |
| `tools/build.sh` | Builds the HTML and the PDF |
| `tools/wave2dio.py` | Converts a `td-*.json5` WaveJSON source into an editable draw.io file. Shared by every chapter |

Generated outputs, kept in the repository: `core-et-uarch.pdf` and `core-et-uarch.html`.

## Building

Needs `asciidoctor` and `asciidoctor-pdf`. Run from this directory.

```sh
tools/build.sh                     # HTML and PDF
asciidoctor core-et-uarch.adoc     # HTML only
asciidoctor-pdf core-et-uarch.adoc # PDF only
```

Figures are committed, so neither draw.io nor the tools below are needed to build
the document. They are needed only to change a figure.

### Editing a block diagram

Open the `*.drawio.png` in draw.io, edit, and export over the same file with the
diagram kept inside it, so the figure remains its own source:

```sh
drawio -x -f png -s 3 -b 10 --embed-diagram -o <figure>.drawio.png <figure>.drawio.png
```

### Regenerating a timing diagram

Needs the `json5` Python module (`pip3 install json5`) and the draw.io CLI.

```sh
python3 tools/wave2dio.py images/ch03/src/td-l0-hit.json5
drawio -x -f png -s 2 -b 10 -o images/ch03/td-l0-hit.png images/ch03/src/td-l0-hit.drawio
```

The intermediate `.drawio` is a build product, not a source; the `.json5` is the
source and is the file to edit.
