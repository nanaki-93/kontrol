"""Read-only structural checks for these planning artifacts; no browser or app."""
from pathlib import Path
from html.parser import HTMLParser
import re
import shutil
import subprocess

root = Path(__file__).resolve().parent

class Document(HTMLParser):
    def __init__(self):
        super().__init__()
        self.refs = []
        self.ids = []

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        for key in ('href', 'src'):
            if key in attributes:
                self.refs.append(attributes[key])
        if 'id' in attributes:
            self.ids.append(attributes['id'])

if not shutil.which('node'):
    raise SystemExit('node unavailable: inline JavaScript syntax has NOT been checked.')
tokens = (root.parent.parent / 'design-system/tokens.css').read_text()
known = set(re.findall(r'(--[a-zA-Z0-9-]+)\s*:', tokens))
errors = []
scripts = 0
pages = sorted(root.glob('*.html'))
for path in pages:
    text = path.read_text()
    document = Document()
    document.feed(text)
    if len(document.ids) != len(set(document.ids)):
        errors.append(f'{path.name}: duplicate ids')
    for ref in document.refs:
        if re.match(r'https?://', ref):
            errors.append(f'{path.name}: external reference {ref}')
        elif not ref.startswith('#') and not (path.parent / ref.split('#')[0]).exists():
            errors.append(f'{path.name}: missing reference {ref}')
    unknown = set(re.findall(r'var\((--[a-zA-Z0-9-]+)', text)) - known
    if unknown:
        errors.append(f'{path.name}: unknown tokens {unknown}')
    for script in re.findall(r'<script>(.*?)</script>', text, re.S):
        result = subprocess.run(['node', '--check'], input=script, text=True, capture_output=True)
        if result.returncode:
            errors.append(f'{path.name}: {result.stderr}')
        scripts += 1
if errors:
    raise SystemExit('\n'.join(errors))
print(f'PASS: {len(pages)} HTML files: local references, unique IDs, CSS tokens; {scripts} inline scripts parsed with node --check.')
print('No rendered layout or native UI behavior was validated.')
