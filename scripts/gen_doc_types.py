#!/usr/bin/env python3
"""Writes CFBundleDocumentTypes into Info.plist.

Every entry uses LSHandlerRank None: FeatherView is listed under "Open With" for these files but Launch
Services never picks it on its own. (Alternate was not enough: when the other editor declares no rank,
e.g. VS Code, macOS started preferring it after it was installed.) The user picks defaults in
FeatherView → 默认打开方式…, which records an explicit choice.
Extensions without a system UTI (.md .go .rs .toml …) are claimed by extension, so FeatherView does
not redefine the type other apps already use for them.
"""
import plistlib, sys

EDITOR_UTIS = """public.plain-text com.apple.log public.c-source public.c-header public.objective-c-source
public.objective-c-plus-plus-source public.c-plus-plus-source public.c-plus-plus-header public.swift-source
public.python-script public.ruby-script com.netscape.javascript-source com.sun.java-source public.php-script
public.perl-script public.shell-script public.bash-script public.zsh-script public.css public.json public.yaml
public.xml com.apple.property-list public.comma-separated-values-text public.tab-separated-values-text
public.html public.source-code public.script public.text""".split()
EDITOR_EXTS = """md markdown mdown mkd mdx go rs cjs jsx tsx kt kts scala cs lua fish sql scss less jsonc toml ini
conf cfg env gradle proto zig dart vue svelte""".split()
VIEWER_UTIS = "public.image public.png public.jpeg com.compuserve.gif public.heic org.webmproject.webp public.tiff com.microsoft.bmp com.adobe.pdf".split()

def entry(name, role, utis=None, exts=None):
    d = {"CFBundleTypeName": name, "CFBundleTypeRole": role, "LSHandlerRank": "None"}
    if utis: d["LSItemContentTypes"] = utis
    if exts: d["CFBundleTypeExtensions"] = exts
    return d

path = sys.argv[1] if len(sys.argv) > 1 else "Info.plist"
with open(path, "rb") as f:
    info = plistlib.load(f)
info["CFBundleDocumentTypes"] = [
    entry("Folder", "Viewer", utis=["public.folder"]),
    entry("Text and source code", "Editor", utis=EDITOR_UTIS),
    entry("Markdown, code and config files", "Editor", exts=EDITOR_EXTS),
    entry("Images and PDF", "Viewer", utis=VIEWER_UTIS),
    entry("Any file", "Viewer", utis=["public.item"]),
]
with open(path, "wb") as f:
    plistlib.dump(info, f, sort_keys=False)
print(f"{path}: {len(EDITOR_UTIS)} text types, {len(EDITOR_EXTS)} extensions, {len(VIEWER_UTIS)} image/PDF types")
