#!/usr/bin/env python3
"""Checks the UI translations (run by `make test`).

Source text is English and wrapped in FTL(@"…") / FTLP(n, @"one", @"other"); the JSON parser's
messages are C strings passed to fail() / failw(). Every key must be translated in each non-English
Resources/<lang>.lproj/Localizable.strings with the same format specifiers, no translation may be
unused, and no Chinese text may appear in the sources outside FTL().

    scripts/l10n.py            check, exit 1 on problems
    scripts/l10n.py --missing  print the untranslated keys as .strings lines, ready to fill in
"""
import glob, json, re, subprocess, sys

DATA_LITERALS = {", \\t\\n，、", "："}       # separators the parser accepts, not UI text
CJK = re.compile(r'[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]')
OBJC = r'@"((?:[^"\\]|\\.)*)"'
SPEC = re.compile(r'%(?:(\d+)\$)?[-+ #0\']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?([@dDuUxXoOfeEgGcCsSpaA%])')


def unescape(s):
    return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), s)


def specifiers(s):
    """Argument types in argument order, so "%2$@ in %1$@" and "%1$@中 %2$@" compare equal."""
    seq, pos, n = {}, False, 0
    for m in SPEC.finditer(s):
        if m.group(2) == '%':
            continue
        t = m.group(2).replace('U', 'u').replace('D', 'd')
        if m.group(1):
            pos = True; seq[int(m.group(1))] = t
        else:
            n += 1; seq[n] = t
    return [seq[k] for k in sorted(seq)], pos


def close_paren(s, i):
    depth, j = 0, i
    while j < len(s):
        c = s[j]
        if c == '"':
            j += 1
            while s[j] != '"':
                j += 2 if s[j] == '\\' else 1
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if not depth:
                return j
        j += 1
    return j


def source_keys():
    keys, problems = {}, []
    for f in sorted(glob.glob('src/*/*.m')):
        s = open(f, encoding='utf-8').read()
        where = lambda i: '%s:%d' % (f, s.count('\n', 0, i) + 1)
        for m in re.finditer(r'\bFTL(P?)\(', s):
            if s[m.start() - 1].isalnum():
                continue
            body = s[m.end() - 1:close_paren(s, m.end() - 1) + 1]
            lits = re.findall(OBJC, body)
            if m.group(1) == 'P' and len(lits) != 2 or not m.group(1) and not re.fullmatch(r'\(\s*' + OBJC + r'\s*\)', body):
                if not (not m.group(1) and body.startswith('(@(')):        # FTL(@(cString)) for fail() messages
                    problems.append('%s: FTL%s needs string literal keys: %s' % (where(m.start()), m.group(1), body[:80]))
                continue
            for k in lits:
                keys.setdefault(unescape(k), where(m.start()))
        for m in re.finditer(r'\bfail(w?)\(&?p, ([^;]*)\);', s):
            lits = re.findall(r'(?<!@)"((?:[^"\\]|\\.)*)"', m.group(2))
            for k in (lits[:1] if m.group(1) else lits):
                keys.setdefault(unescape(k), where(m.start()))
        for m in re.finditer(OBJC, re.sub(r'//[^\n]*', '', s)):
            if CJK.search(m.group(1)) and m.group(1) not in DATA_LITERALS:
                problems.append('%s: Chinese text in the source; write English inside FTL(): "%s"' % (f, m.group(1)[:60]))
    return keys, problems


def load(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', path]))


def main():
    keys, problems = source_keys()
    tables = [t for t in sorted(glob.glob('Resources/*.lproj/Localizable.strings')) if '/en.lproj/' not in t]   # English: keys are the text
    if not tables:
        problems.append('no Resources/*.lproj/Localizable.strings')
    for t in tables:
        table = load(t)
        missing = [k for k in keys if k not in table]
        if '--missing' in sys.argv:
            for k in sorted(missing):
                print('"%s" = "";' % k.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n'))
            continue
        for k in missing:
            problems.append('%s: missing "%s" (used at %s)' % (t, k, keys[k]))
        for k, v in table.items():
            if k not in keys:
                problems.append('%s: unused translation "%s"' % (t, k))
            elif specifiers(k)[0] != specifiers(v)[0]:
                problems.append('%s: format specifiers differ: "%s" → "%s"' % (t, k, v))
    if '--missing' in sys.argv:
        return 0
    for p in problems:
        print(p)
    print('l10n: %d keys, %d table(s), %s' % (len(keys), len(tables), 'ok' if not problems else '%d problem(s)' % len(problems)))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
