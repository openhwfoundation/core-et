# Documentation

Everything written about the open-sourced CORE-ET design. The RTL it describes is in [`rtl/`](../rtl/).

Two kinds of material live here, and the difference matters:

- **`uarch_spec/`** is the new micro-architecture document for this repository, currently under development. It is written from both sources together, the RTL and the legacy documents, and it is the deliverable this folder exists to produce.
- **`arch/`, `uarch/` and `uarch_md/`** are the legacy Esperanto documents. They are reference material only.

Where a legacy document and `uarch_spec/` disagree, **the RTL is the source of truth**.

## Folders

| Folder | Contents |
|---|---|
| [`uarch_spec/`](uarch_spec/) | The CORE-ET micro-architecture: AsciiDoc source, figures, build scripts and the generated HTML and PDF. Its own [README](uarch_spec/README.md) lists the chapters and what each one covers, and explains how to build the document and how to edit a figure. |
| [`arch/`](arch/) | Architecture-level Esperanto documents: datasheet, programmer's reference manual, introduction, errata, card datasheet. Source for chip-level facts, such as the ET-SoC-1 overview that opens the reference. |
| [`uarch/`](uarch/) | Legacy micro-architecture specifications, one PDF per unit: Minion, Neighborhood MAS, Minion Shire, Shire Cache, ET-Link, VPU, DCache, Front End and I-cache descriptions. |
| [`uarch_md/`](uarch_md/) | Markdown conversions of the PDFs in `uarch/`, one folder per document, with the extracted figures. Easier to search and to quote from than the PDFs. |

## Conventions

Rules followed in writing `uarch_spec/`, and to be followed when adding to it. They do not apply to the legacy folders, which are kept as they were received.

- Every statement in `uarch_spec/` must be traceable to the RTL or to a document in `arch/` or `uarch/`.
- `dv/` and `test/` are not used as sources.
- Figures drawn for this document keep an editable source; figures taken from a legacy document do not. The naming distinguishes them, and [`uarch_spec/README.md`](uarch_spec/README.md) says how to edit each kind.
