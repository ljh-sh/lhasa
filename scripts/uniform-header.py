#!/usr/bin/env python3
"""
Refactor ljh-sh/lhasa Pages site: every page gets a section nav.

Sections: install · usage · formats · security · build-audit
Homepage active = "home"; subpages active = their stem.

The current page item is rendered as <strong>; others as <a href>.
The lang switch uses <strong> on the active lang code.
"""
import re, sys
from pathlib import Path

SECTION_LABELS = {
    'en':    ['install', 'usage', 'formats', 'security', 'build audit', '↑ home'],
    'zh-CN': ['安装',     '用法', '格式',   '安全',     '构建审计',   '↑ 首页'],
    'zh-TW': ['安裝',     '用法', '格式',   '資安',     '建置稽核',   '↑ 首頁'],
    'ja':    ['インストール', '使い方', 'フォーマット', 'セキュリティ', 'ビルド監査', '↑ ホーム'],
}
SECTIONS = ['install', 'usage', 'formats', 'security', 'build-audit']

HTML_LANG_MAP = {
    'en': 'en',
    'zh-CN': 'zh-CN',
    'zh-Hant': 'zh-TW',
    'ja': 'ja',
}

# Title prefix per lang, used by the lang switch as label.
LANGS = ['en', 'zh-CN', 'zh-TW', 'ja']


def render_section_nav(lang_code, current_file, is_top_level):
    labels = SECTION_LABELS[lang_code]
    prefix = '' if is_top_level else '../'
    parts = []
    for i, name in enumerate(SECTIONS):
        label = labels[i]
        href = prefix + name + '.html'
        if name == current_file:
            parts.append('<strong>' + label + '</strong>')
        else:
            parts.append('<a href="' + href + '">' + label + '</a>')
    home_label = labels[5]
    home_href = prefix + 'index.html'
    if current_file == 'home':
        parts.append('<strong>' + home_label + '</strong>')
    else:
        parts.append('<a href="' + home_href + '">' + home_label + '</a>')
    return ' · '.join(parts)


def render_lang_switch(lang_code, current_file, is_top_level):
    """Active language rendered as <strong>."""
    prefix = '' if is_top_level else '../'

    def href_for(target_lang):
        if target_lang == 'en':
            return prefix + current_file + '.html'
        return prefix + target_lang + '/' + current_file + '.html'

    parts = []
    for lang_target in LANGS:
        if lang_target == lang_code:
            parts.append('<strong>' + lang_target + '</strong>')
        else:
            parts.append('<a href="' + href_for(lang_target) + '">'
                         + lang_target + '</a>')
    return ' · '.join(parts)


def current_file_from_path(p):
    name = p.name
    if name.endswith('.html'):
        return name[:-5]
    return name


def is_top_level_path(p):
    rel = p.relative_to(Path('docs'))
    return len(rel.parts) == 1


def infer_lang(html):
    m = re.search(r'<html\s+lang="([^"]+)"', html)
    if not m: return 'en'
    return HTML_LANG_MAP.get(m.group(1), 'en')


def refactor_file(path):
    html = path.read_text()
    lang = infer_lang(html)
    current = current_file_from_path(path)
    if current == 'index':
        section_current = 'home'
    else:
        section_current = current
    top = is_top_level_path(path)

    nav_inner = render_section_nav(lang, section_current, top)
    header_inner = (
        '<nav class="section-nav">' + nav_inner + '</nav>\n'
        '    <div class="lang-switch">' + render_lang_switch(lang, current, top) + '</div>'
    )

    new_header = (
        '<header class="page-header">\n'
        '    ' + header_inner + '\n'
        '</header>'
    )

    new = re.sub(
        r'<header class="page-header">.*?</header>',
        new_header,
        html,
        count=1,
        flags=re.DOTALL
    )
    if new == html:
        return False
    path.write_text(new)
    return True


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else 'docs')
    changed = 0
    for f in sorted(root.rglob('*.html')):
        if refactor_file(f):
            changed += 1
            print('  OK', f)
    print(f'\n{changed} files updated.')


if __name__ == '__main__':
    main()
