#!/usr/bin/env bash
# Build technical_report.docx from technical_report.org
# Requires: pandoc >= 3.8, python3
set -euo pipefail
cd "$(dirname "$0")"

echo "Building docx with pandoc..."
pandoc technical_report.org \
  -o technical_report_raw.docx \
  --citeproc \
  --bibliography=Wildfire.bib \
  --csl=international-journal-of-wildland-fire.csl \
  --resource-path=.:img \
  --lua-filter=resolve-crossrefs.lua \
  --lua-filter=fix-bullets.lua \
  --metadata link-citations=true

echo "Fixing bullet symbols..."
python3 -c "
import zipfile
src = 'technical_report_raw.docx'
dst = 'technical_report.docx'
with zipfile.ZipFile(src, 'r') as zin:
    with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as zout:
        for item in zin.namelist():
            data = zin.read(item)
            if item == 'word/numbering.xml':
                text = data.decode('utf-8')
                text = text.replace('w:ascii=\"Symbol\"', 'w:ascii=\"Calibri\"')
                text = text.replace('w:hAnsi=\"Symbol\"', 'w:hAnsi=\"Calibri\"')
                text = text.replace('\uf0b7', '\u2022')
                text = text.replace('\uf0a7', '\u2022')
                text = text.replace('w:ascii=\"Courier New\"', 'w:ascii=\"Calibri\"')
                text = text.replace('w:hAnsi=\"Courier New\"', 'w:hAnsi=\"Calibri\"')
                data = text.encode('utf-8')
            zout.writestr(item, data)
"

rm technical_report_raw.docx
echo "Done: technical_report.docx"
