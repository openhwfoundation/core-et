# Legacy Micro-Architecture Documents (Markdown Conversion)

This folder contains Markdown versions of every PDF in [`docs/uarch/`](../uarch/). The text is converted word for word, and all figures are kept.

- **Purpose:** these files are the searchable, diff-able source material for the new micro-architecture reference. They are a faithful transcription of the originals, with no corrections and no edits to the content.
- **Revision:** the source PDFs describe the **first (A0) revision** of the ET-SoC-1 design. The RTL in [`rtl/`](../../rtl/) is a later revision, so these documents may disagree with the implementation. Any such discrepancy is resolved in the new document, not here.
- **Status:** these files are reference material only. They will be retired together with the PDFs once the new document supersedes them.

## Layout

```
uarch_md/
├── README.md                          ← this index
└── <Document-Name>/
    ├── <Document-Name>.md             ← full text, tables, captions
    └── figures/
        └── pageNNN_<id>.png           ← figures; NNN = 1-based page number in the source PDF
```

The folder names follow the PDF file names so the two can be traced to each other. Spaces are replaced by `-`. The original misspelling "Neigborhood" is kept.

## Index

| Document | Source PDF | Pages | Latest rev. (from revision table) | Figures | Subject |
|---|---|---:|---|---:|---|
| [Minion Description](Minion-Description/Minion-Description.md) | `Minion Description.pdf` | 12 | 0.1.2 (2022-07-11) | 1 | Top-level Minion overview and interface list |
| [FE/Intpipe Description](FE-Intpipe-Description/FE-Intpipe-Description.md) | `FE-Intpipe-Description.pdf` | 27 | 0.3.2 (2022-07-11) | 8 | Frontend and integer pipeline, stalls, CSR file, MulDiv |
| [Frontend-ICache Interface](Frontend-ICache-Interface/Frontend-ICache-Interface.md) | `Frontend-ICache-Interface.pdf` | 18 | 1.0.1 (2021-10-07) | 3 | Frontend ↔ shared ICache bus, livelock issue and fix |
| [Minion DCache Description](Minion-DCache-Description/Minion-DCache-Description.md) | `Minion DCache Description.pdf` | 62 | 0.5.2 (2022-07-11) | 25 | L1 data cache, miss handler, replay queue, TensorLoad, CacheOps |
| [Minion VPU Specification](Minion-VPU-Specification/Minion-VPU-Specification.md) | `Minion VPU Specification.pdf` | 99 | 0.5.2 (2022-07-12) | 44 | Vector unit pipeline, TXFMA, TIMA, transcendental unit, tensor ops |
| [Neighborhood Description (MAS)](CORE-ET-Neigborhood-MAS/CORE-ET-Neigborhood-MAS.md) | `CORE-ET-Neigborhood-MAS.pdf` | 52 | 1.0.2 (2021-10-14) | 17 | Neighborhood datapaths, FLB, FCC, PMU, PTW, ESRs, clocks, voltage domains |
| [Neighborhood ICache Description](Neighborhood-ICache-Description/Neighborhood-ICache-Description.md) | `Neighborhood-ICache-Description.pdf` | 28 | 0.2.1 (2021-10-29) | 8 | L0 micro-caches, L1 ICache, prefetch, ECC and error logging |
| [Cooperative TensorLoad Description](Cooperative-TensorLoad-Description/Cooperative-TensorLoad-Description.md) | `Cooperative-TensorLoad-Description.pdf` | 19 | 0.2.1 (2021-11-24) | 3 | DCache and Neighborhood cooperative TensorLoad |
| [ET-Link Specification](ET-Link-Specification/ET-Link-Specification.md) | `ET-Link-Specification.pdf` | 34 | 0.5.2 (2021-10-20) | 6 | On-chip request/response protocol and operations |
| [Minion Shire Description](CORE-ET-Minion-Shire-Description/CORE-ET-Minion-Shire-Description.md) | `CORE-ET Minion Shire Description.pdf` | 21 | 0.7.1 (2021-10-18) | 5 | Shire-level integration, clocks, resets, voltage domains |
| [Shire Cache Specification](CORE-ET-Shire-Cache-Specification/CORE-ET-Shire-Cache-Specification.md) | `CORE-ET-Shire-Cache-Specification.pdf` | 131 | — | 86 | L2/L3/scratchpad Shire Cache (not part of the open-sourced RTL) |
| [Minion Shire DLL Constraints](Minion-Shire-DLL-Constraints/Minion-Shire-DLL-Constraints.md) | `Minion Shire DLL Constraints.pdf` | 23 | — | 15 | DLL delay constraints and probe points |
| [Minion Shire DLL Delay Control](Minion-Shire-DLL-Delay-Control/Minion-Shire-DLL-Delay-Control.md) | `Minion Shire DLL Delay Control.pdf` | 15 | — | 8 | Programmable delay cells and DLL delay estimation |

The image [`docs/uarch/cpu_subsystem/images/cpuss_diagram.png`](../uarch/cpu_subsystem/images/cpuss_diagram.png) is not a PDF and was not converted.

## Conversion method

1. **Extraction:** each PDF was converted with PyMuPDF / `pymupdf4llm` at 200 dpi. This preserved:
   - heading levels
   - bullet and numbered lists
   - tables, as pipe tables with `<br>` for line breaks inside cells
   - bold, italic and underline, including hyperlink underlines
   - `<mark>` highlights that exist in the originals
2. **Figures:** raster images and vector drawings are both saved as PNG under `figures/`. Duplicate text that the extractor produced *from inside* a figure was removed, because that text stays visible in the image.
3. **Verification against the PDF:** the Markdown was checked against `pdftotext` output of the same PDF.
   - *Word coverage:* every body-text line of 8 or more words was confirmed to be present.
   - *Stray words:* no word appears that does not exist in the source PDF.
   - *Captions:* every figure and table caption was confirmed to be present.
   - *Link integrity:* every image link resolves to a file, and every figure file is referenced.
4. **Repairs for extraction artifacts only.** No wording was changed. Each repair restores text as it appears in the PDF:
   - **Spaces:** a missing space between two words (e.g. "Descriptiondocument" → "Description document") was restored only when both halves are words in the source PDF and appear adjacent in its text.
   - **Absorbed content:**
     - Captions, table rows and bullets that the extractor had pulled into an adjacent figure image were restored as text.
     - Text that had been captured as an image was replaced by the text itself (e.g. `addr_LRAM = { set[3:0], idx[0], way[1:0] }`).
     - Figure images that contained only a caption were removed, since the caption now exists as text.
   - **Tables:**
     - Tables split by page breaks were merged, and page-repeated header rows were dropped.
     - Title rows split across cells, and words broken across cells, were rejoined.
     - Garbled cells in the VPU instruction tables were re-transcribed from the PDF text.
     - The VPU debug-bus table rows that had been rendered as images were re-transcribed as table rows.
   - **Register diagrams (Shire Cache Specification):** some register bit-field diagrams are drawn in the PDF as tables with vertical bit numbers and could not be represented faithfully as Markdown tables. They were replaced by exact crops of the diagram from the PDF page, named `pageNNN_<name>.png` with the register name as alt text:
     - L3 and Idx CacheOp address fields
     - L3 tag aliasing
     - `shire_cache_build_config`
     - `esr_sc_perfmon_*`
     - `sbe_dbe_count`
     - `err_log_info` formats
     - `ecc_scrub_status`
     - the EVENT Mode 0 qualifier matrix. For this matrix, the qualifier, ESR bit and description columns are also provided as a text table.
   - **Running headers:** page headers that leaked into the Shire Cache text ("Shire Cache Specification") were removed.

## Known limitations

- **Text inside figures exists only in the images.** This covers FSM state labels, block-diagram labels and register diagrams, and it is why word coverage is lower for the DCache (≈92%) and Shire Cache (≈94%) documents than for the rest (≥98.7%).
- **Defects in the source PDFs are preserved.** Some source figures have clipped titles or missing labels, for example the Shire Cache sequence diagrams and DCache Figure 10. The figures here match the PDFs.
- **Some multi-part vector figures are stored as several consecutive images.** They appear directly one after another in the Markdown.
- **Table-of-contents page numbers refer to the original PDF pages.** Intra-document links such as "see Clocks" are plain text, as in the PDFs.
