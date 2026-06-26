#!/usr/bin/env python3
"""Extract GFM *extension* examples from cmark-gfm test/spec.txt into the
CommonMark reference spec.json shape ({markdown, html, example, section}).

GFM's spec.txt is a superset of CommonMark; we keep only the sections whose
name ends with "(extension)" so the corpus does not duplicate CommonMark.

Usage:
    curl -sO https://raw.githubusercontent.com/github/cmark-gfm/0.29.0.gfm.13/test/spec.txt
    python3 Scripts/extract_gfm_corpus.py spec.txt \
        Tests/MD2CoreTests/Corpus/gfm-0.29.extensions.spec.json
"""
import json
import re
import sys
from collections import Counter

SPEC_TXT = sys.argv[1]
OUT_JSON = sys.argv[2]

header_re = re.compile(r'#+ ')
fence = "`" * 32

tests = []
state = 0  # 0 text, 1 markdown, 2 html
markdown_lines, html_lines = [], []
headertext = ''
example_number = 0
start_line = end_line = 0

with open(SPEC_TXT, encoding='utf-8') as f:
    for line_number, line in enumerate(f, start=1):
        stripped = line.strip()
        # CommonMark uses bare "<32 backticks> example"; GFM tags extension
        # examples with an info string, e.g. "... example table".
        if stripped == fence + " example" or stripped.startswith(fence + " example "):
            state = 1
        elif state == 2 and stripped == fence:
            state = 0
            example_number += 1
            end_line = line_number
            tests.append({
                "markdown": ''.join(markdown_lines).replace('→', '\t'),
                "html": ''.join(html_lines).replace('→', '\t'),
                "example": example_number,
                "start_line": start_line,
                "end_line": end_line,
                "section": headertext,
            })
            start_line = 0
            markdown_lines, html_lines = [], []
        elif stripped == ".":
            state = 2
        elif state == 1:
            if start_line == 0:
                start_line = line_number - 1
            markdown_lines.append(line)
        elif state == 2:
            html_lines.append(line)
        elif state == 0 and header_re.match(line):
            headertext = header_re.sub('', line).strip()

extensions = [t for t in tests if t['section'].endswith('(extension)')]
with open(OUT_JSON, 'w', encoding='utf-8') as f:
    json.dump(extensions, f, ensure_ascii=False, indent=2)
    f.write('\n')

print(f"total examples parsed: {len(tests)}")
print(f"extension examples kept: {len(extensions)}")
for section, n in Counter(t['section'] for t in extensions).items():
    print(f"  {section}: {n}")
