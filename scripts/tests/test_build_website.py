import base64
from html.parser import HTMLParser
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class Page(HTMLParser):
    def __init__(self, content):
        super().__init__(); self.tags=[]; self.feed(content)
    def handle_starttag(self, tag, attributes): self.tags.append((tag,dict(attributes)))

class WebsiteTests(unittest.TestCase):
    def test_standalone_assets_and_release_links(self):
        content=(ROOT/'website/echo-voice.html').read_text()
        page=Page(content)
        ids={attrs['id'] for _,attrs in page.tags if 'id' in attrs}
        images=[attrs for tag,attrs in page.tags if tag=='img']
        self.assertEqual(len(images),3)
        for attrs in images:
            self.assertTrue(attrs.get('alt'))
            self.assertTrue(attrs['src'].startswith('data:image/jpeg;base64,'))
            self.assertTrue(base64.b64decode(attrs['src'].split(',',1)[1]).startswith(b'\xff\xd8'))
        for tag,attrs in page.tags:
            self.assertFalse(tag in ('script','link') and ('src' in attrs or attrs.get('rel')=='stylesheet'))
            if attrs.get('href','').startswith('#'): self.assertIn(attrs['href'][1:],ids)
        release=json.loads((ROOT/'website/release.json').read_text())
        links={attrs['href'] for _,attrs in page.tags if 'href' in attrs}
        if not release['direct']['available']: self.assertFalse(any('/releases/download/' in link for link in links))
        if not release['appStore']['available']: self.assertFalse(any('apps.apple.com' in link for link in links))
        self.assertNotIn('{{',content)
        self.assertIn('prefers-reduced-motion',content)
        self.assertIn('class="table-scroll"',content)
        self.assertIn('privacy.html',links)
        self.assertIn('support.html',links)
        for name in ('privacy.html','support.html'):
            page=Page((ROOT/'website'/name).read_text())
            self.assertIn('viewport', (ROOT/'website'/name).read_text())
            for tag,attrs in page.tags:
                self.assertFalse(tag=='script')
                self.assertFalse(tag=='link' and attrs.get('rel')=='stylesheet')
        support=(ROOT/'website/support.html').read_text()
        self.assertIn('support@example.com', support)
        self.assertIn('placeholder', support.lower())
