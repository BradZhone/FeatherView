#import <Foundation/Foundation.h>

// Jupyter .ipynb → Markdown for the native preview: Markdown cells as they are, code cells as fenced code
// in the notebook's language, outputs (text, errors, PNG / JPEG / SVG images) below them.
// Images are written into imageDir (created if needed) and referenced by absolute path.
// On a broken file returns a short Markdown explanation instead.
NSString *NotebookToMarkdown(NSData *json, NSString *imageDir, NSUInteger *cellCount);
