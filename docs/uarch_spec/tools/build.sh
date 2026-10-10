#!/bin/sh
# Build the micro-architecture reference: HTML and PDF.
# Run from docs/uarch_spec:  tools/build.sh
set -e
cd "$(dirname "$0")/.."
asciidoctor core-et-uarch.adoc
asciidoctor-pdf core-et-uarch.adoc
echo "built core-et-uarch.html, core-et-uarch.pdf"
