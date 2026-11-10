#import <Foundation/Foundation.h>
#import "Markdown.h"

static int failures = 0, total = 0;

static void T(NSString *md, NSString *html) {
    total++;
    NSString *got = MDRenderHTML(MDParse(md));
    if (![got isEqualToString:html]) {
        failures++;
        fprintf(stderr, "FAIL md: %s\n   want: %s\n   got:  %s\n", md.UTF8String, html.UTF8String, got.UTF8String);
    }
}

static void C(BOOL ok, const char *what) { total++; if (!ok) { failures++; fprintf(stderr, "FAIL %s\n", what); } }

int main(void) {
    @autoreleasepool {
        // emphasis
        T(@"*a* **b** ***c***", @"<p><em>a</em> <strong>b</strong> <em><strong>c</strong></em></p>");
        T(@"_a_ __b__", @"<p><em>a</em> <strong>b</strong></p>");
        T(@"snake_case_name and 2*3*4", @"<p>snake_case_name and 2<em>3</em>4</p>");
        T(@"*foo**bar**baz*", @"<p><em>foo<strong>bar</strong>baz</em></p>");
        T(@"**foo*", @"<p>*<em>foo</em></p>");
        T(@"a * b * c", @"<p>a * b * c</p>");
        T(@"~~del~~ ~one~", @"<p><del>del</del> <del>one</del></p>");
        T(@"`a*b*c` ``x`y``", @"<p><code>a*b*c</code> <code>x`y</code></p>");
        T(@"\\*not\\* &amp; &copy; &#20013;", @"<p>*not* &amp; © 中</p>");
        // links / images
        T(@"[a](http://x.com) [b](<u v> \"t\")", @"<p><a href=\"http://x.com\">a</a> <a href=\"u v\">b</a></p>");
        T(@"[w](https://en.wikipedia.org/wiki/A_(b))", @"<p><a href=\"https://en.wikipedia.org/wiki/A_(b)\">w</a></p>");
        T(@"[**bold** link](u)", @"<p><a href=\"u\"><strong>bold</strong> link</a></p>");
        T(@"[x][r] [r] [y][]\n\n[r]: /url \"T\"", @"<p><a href=\"/url\">x</a> <a href=\"/url\">r</a> [y][]</p>");
        T(@"[not a link] and [x](", @"<p>[not a link] and [x](</p>");
        T(@"![alt *t*](img.png \"title\")", @"<p><img src=\"img.png\" alt=\"alt t\"></p>");
        T(@"[![badge](b.svg)](https://ci)", @"<p><a href=\"https://ci\"><img src=\"b.svg\" alt=\"badge\"></a></p>");
        T(@"<https://a.b/c> <me@x.org>", @"<p><a href=\"https://a.b/c\">https://a.b/c</a> <a href=\"mailto:me@x.org\">me@x.org</a></p>");
        T(@"see https://x.com/a. and www.y.org", @"<p>see <a href=\"https://x.com/a\">https://x.com/a</a>. and <a href=\"http://www.y.org\">www.y.org</a></p>");
        T(@"(see https://x.com/a)", @"<p>(see <a href=\"https://x.com/a\">https://x.com/a</a>)</p>");
        T(@"[https://x.com](https://x.com)", @"<p><a href=\"https://x.com\"><a href=\"https://x.com\">https://x.com</a></a></p>");
        T(@"a <b>bold</b> <br/> c", @"<p>a <b>bold</b> <br/> c</p>");
        T(@"line one  \nline two\\\nthree\nfour", @"<p>line one<br>line two<br>three\nfour</p>");
        // headings
        T(@"# H1\n## H2 ##\n###### six\n####### seven", @"<h1>H1</h1><h2>H2</h2><h6>six</h6><p>####### seven</p>");
        T(@"Title\n=====\nSub\n---", @"<h1>Title</h1><h2>Sub</h2>");
        T(@"#nospace", @"<p>#nospace</p>");
        // code
        T(@"```js\nlet a = 1 < 2;\n```", @"<pre lang=\"js\">let a = 1 &lt; 2;</pre>");
        T(@"~~~\nraw ``` inside\n~~~", @"<pre>raw ``` inside</pre>");
        T(@"    indented\n    code\n\npara", @"<pre>indented\ncode</pre><p>para</p>");
        T(@"para\n    not code", @"<p>para\nnot code</p>");
        T(@"```\nunclosed", @"<pre>unclosed</pre>");
        // lists
        T(@"- a\n- b\n* c", @"<ul><li>a</li><li>b</li></ul><ul><li>c</li></ul>");
        T(@"- a\n\n- b", @"<ul><li><p>a</p></li><li><p>b</p></li></ul>");
        T(@"3. x\n4. y", @"<ol start=\"3\"><li>x</li><li>y</li></ol>");
        T(@"- a\n  - b\n  - c\n- d", @"<ul><li>a<ul><li>b</li><li>c</li></ul></li><li>d</li></ul>");
        T(@"- [ ] todo\n- [x] done", @"<ul><li>[ ] todo</li><li>[x] done</li></ul>");
        T(@"- one\ncontinued", @"<ul><li>one\ncontinued</li></ul>");
        T(@"- item\n\n  second para\n- next", @"<ul><li><p>item</p><p>second para</p></li><li><p>next</p></li></ul>");
        T(@"- a\n  ```\n  code\n  ```", @"<ul><li>a<pre>code</pre></li></ul>");
        T(@"The year\n2023. was good", @"<p>The year\n2023. was good</p>");
        T(@"text\n- list", @"<p>text</p><ul><li>list</li></ul>");
        // quotes
        T(@"> quote\nlazy\n> > nested", @"<blockquote><p>quote\nlazy</p><blockquote><p>nested</p></blockquote></blockquote>");
        // tables
        T(@"| a | b | c |\n|:--|:-:|--:|\n| 1 | `x\\|y` | 3 |\n| 4 |",
          @"<table><tr><th align=\"left\">a</th><th align=\"center\">b</th><th align=\"right\">c</th></tr>"
          @"<tr><td align=\"left\">1</td><td align=\"center\"><code>x|y</code></td><td align=\"right\">3</td></tr>"
          @"<tr><td align=\"left\">4</td><td align=\"center\"></td><td align=\"right\"></td></tr></table>");
        T(@"intro\na | b\n--|--\n1 | 2", @"<p>intro</p><table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>");
        T(@"a | b\n-- | x", @"<p>a | b\n-- | x</p>");
        // html + rules
        T(@"<div align=\"center\">\n  <img src=\"x.png\">\n</div>\n\n*after*", @"<div align=\"center\">\n  <img src=\"x.png\">\n</div><p><em>after</em></p>");
        T(@"<!-- c\nomment -->\ntext", @"<!-- c\nomment --><p>text</p>");
        T(@"***\n- - -\n___", @"<hr><hr><hr>");

        // source lines (used for scroll sync)
        MDDocument *d = MDParse(@"# T\n\npara\nmore\n\n- a\n- b\n\n```\nc\n```\n> q");
        NSArray *lines = [d.blocks valueForKey:@"line"];
        C([lines isEqualToArray:(@[@0, @2, @5, @8, @11])], "block source lines");
        C(d.blocks[2].children[1].line == 6, "list item line");
        // slugs
        C([MDSlug(@"Hello, World!") isEqualToString:@"hello-world"], "slug ascii");
        C([MDSlug(@"安装 Feather") isEqualToString:@"安装-feather"], "slug cjk");
        C([MDSlug(@"API_v2 - notes") isEqualToString:@"api_v2---notes"], "slug punctuation");
        C([MDPlainText(MDParseInline(@"Use `make` **now**", nil)) isEqualToString:@"Use make now"], "plain text");
        // robustness: weird input must not crash
        for (NSString *s in @[@"", @"\n\n", @"[", @"]", @"![", @"<", @"&", @"*", @"`", @"|", @"- ", @"1.", @"> ", @"```", @"[a](", @"<a href=\"", @"*_*_~~"])
            MDRenderHTML(MDParse(s));
        C(YES, "no crash on fragments");

        // emphasis and links per the CommonMark spec (the linear-time rewrite must agree)
        T(@"*foo**bar*", @"<p><em>foo**bar</em></p>");
        T(@"*foo *bar**", @"<p><em>foo <em>bar</em></em></p>");
        T(@"***foo** bar*", @"<p><em><strong>foo</strong> bar</em></p>");
        T(@"*foo**bar***", @"<p><em>foo<strong>bar</strong></em></p>");
        T(@"foo***bar***baz", @"<p>foo<em><strong>bar</strong></em>baz</p>");
        T(@"**foo*bar*baz**", @"<p><strong>foo<em>bar</em>baz</strong></p>");
        T(@"*a **b** c*", @"<p><em>a <strong>b</strong> c</em></p>");
        T(@"*[foo*](/uri)", @"<p>*<a href=\"/uri\">foo*</a></p>");
        T(@"[foo [bar](/u)](/v)", @"<p>[foo <a href=\"/u\">bar</a>](/v)</p>");
        T(@"[a](/u) [b [c](/v)](/w) [d](/x)", @"<p><a href=\"/u\">a</a> [b <a href=\"/v\">c</a>](/w) <a href=\"/x\">d</a></p>");
        T(@"![a [b](/u) c](/i)", @"<p><img src=\"/i\" alt=\"a b c\"></p>");
        T(@"` a `` b ` and ``c``", @"<p><code>a `` b</code> and <code>c</code></p>");
        T(@"x ``` y `` z ` w", @"<p>x ``` y `` z ` w</p>");

        // front matter is metadata, not a heading
        T(@"---\ntitle: Hello\ntags: [a, b]\nlist:\n  - x\n  - y\n---\n# Body", @"<table><tr><th>Property</th><th>Value</th></tr><tr><td>title</td><td>Hello</td></tr>"
          @"<tr><td>tags</td><td>a, b</td></tr><tr><td>list</td><td>x, y</td></tr></table><h1>Body</h1>");
        T(@"---\nauthor: \"*me* [x](y)\"\n---\ntext", @"<table><tr><th>Property</th><th>Value</th></tr><tr><td>author</td><td>*me* [x](y)</td></tr></table><p>text</p>");
        T(@"+++\ntitle = \"Toml\"\n+++\nbody", @"<table><tr><th>Property</th><th>Value</th></tr><tr><td>title</td><td>Toml</td></tr></table><p>body</p>");
        T(@"---\nnested:\n  a: 1\n---\nbody", @"<pre lang=\"yaml\">nested:\n  a: 1</pre><p>body</p>");
        T(@"---\n---\nbody", @"<p>body</p>");
        T(@"\uFEFF---\nk: v\n---\n", @"<table><tr><th>Property</th><th>Value</th></tr><tr><td>k</td><td>v</td></tr></table>");
        T(@"text\n---\nmore", @"<h2>text</h2><p>more</p>");                  // later: still a setext heading
        T(@"---\nnot closed", @"<hr><p>not closed</p>");
        C(MDParse(@"---\na: 1\n---\n\npara").blocks[1].line == 4, "lines after front matter keep their numbers");

        // pathological input stays fast (each was quadratic: seconds for ~100 KB)
        NSString *(^rep)(NSString *, NSUInteger) = ^(NSString *s, NSUInteger k) { return [@"" stringByPaddingToLength:s.length * k withString:s startingAtIndex:0]; };
        NSDictionary<NSString *, NSString *> *slow = @{
            @"matched emphasis": rep(@"*a* ", 30000), @"unmatched closers": rep(@"a* ", 30000), @"alternating": rep(@"*a_ ", 30000),
            @"nested brackets": [rep(@"[", 30000) stringByAppendingString:rep(@"]", 30000)],
            @"brackets then links": [rep(@"[", 20000) stringByAppendingString:rep(@"[a](b)", 20000)],
            @"nested labels": [rep(@"[a", 20000) stringByAppendingString:rep(@"]", 20000)],
            @"unclosed titles": rep(@"[a](b \"", 20000), @"unclosed comments": rep(@"<!-- ", 20000),
            @"code runs": [rep(@"`", 300) stringByAppendingString:rep(@"x``` `` ", 20000)],
            @"url parens": [@"https://x.y/" stringByAppendingString:rep(@")", 50000)],
        };
        for (NSString *name in slow) {
            CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
            MDDocument *doc = MDParse(slow[name]);
            for (MDBlock *b in doc.blocks) if (b.text) [doc inlines:b.text];
            double secs = CFAbsoluteTimeGetCurrent() - t0;
            C(secs < 1.5, [NSString stringWithFormat:@"%@ parses in %.2f s", name, secs].UTF8String);
        }

        // nesting is capped, so parsing and rendering can't run out of stack
        NSMutableString *lists = [NSMutableString string];
        for (NSUInteger k = 0; k < 300; k++) [lists appendFormat:@"%@- x\n", [@"" stringByPaddingToLength:k * 2 withString:@" " startingAtIndex:0]];
        NSUInteger depth = 0;
        for (MDBlock *b = MDParse(lists).blocks.firstObject; b.children.count; b = b.children.lastObject) depth++;
        C(depth > 40 && depth < 120, [NSString stringWithFormat:@"300 nested lists capped (%lu levels)", (unsigned long)depth].UTF8String);
        C(MDRenderHTML(MDParse([rep(@">", 200000) stringByAppendingString:@" deep"])).length > 0, "200 000 nested quotes");
        C(MDRenderHTML(MDParse([[rep(@"*", 100000) stringByAppendingString:@"a"] stringByAppendingString:rep(@"*", 100000)])).length > 0, "100 000 nested emphasis");
        C(MDRenderHTML(MDParse([[rep(@"[", 50000) stringByAppendingString:@"a"] stringByAppendingString:rep(@"](u)", 50000)])).length > 0, "50 000 nested links");
        C(MDRenderHTML(MDParse([[rep(@"![", 50000) stringByAppendingString:@"a"] stringByAppendingString:rep(@"](u)", 50000)])).length > 0, "50 000 nested images");
    }
    if (failures) { printf("%d/%d markdown failure(s)\n", failures, total); return 1; }
    printf("all %d markdown tests passed\n", total);
    return 0;
}
