# Designer workspace scratch demo

The Designer usability overhaul is on `feat/byod-signature-sender`, deployed to `portwood-ai-journey`. No production deployment, package release, commit or push was made.

## Try it

1. Open the Portwood command hub → **My templates**. In **Your templates**, choose **Design** from the actions for **Designer usability lab - Quote**. This is a separate inactive demo clone.
2. Click text and type. The steady toolbar has **＋ Insert**, **Fields**, **Page**, font/size and Bold/Italic/Underline. **More** exposes alignment, lists, colour and further formatting. No Salesforce `/` shortcut is taken over.
3. Click a paragraph, image or table. Its inspector provides **Move up/down**, **Duplicate**, **Remove** and **Add text below**. Table controls include rows, columns, merged-cell selection, borders and fills. Shift-click a second cell to select a rectangle.
4. **Placement → Place at coordinates** supports left/top/width in inches, relative to the printable area. The sample's top-right paragraph demonstrates it. Flowing text is the default.
5. **Font family → More fonts…** shows approved native-PDF faces. The sample uses Lato Regular and Bold. Missing variants give guidance; additional faces are managed in **Assets → Fonts**.
6. **Page** adjusts size/orientation/margins. Running header/footer text is editable on the sheet; page-number controls are under Document layout.
7. **Preview**, choose **Northstar - AI authoring demo**, then **Generate PDF**. This renders the current draft through Salesforce's native PDF engine. **Back to editing** returns to the draft.
8. **Save** creates a version. **Document actions** contains settings, version history, source, prompt/Agentforce refinement and classic Designer. **Settings → Done** keeps the draft; save before refreshing or leaving.

Advanced users can use the visible **Visual / HTML** switch. The separate **HTML source demo - Quote** (`a0DQL00000eWkIR2A0`) demonstrates direct wording and CSS edits, preserved Lato font bindings, source-to-native-PDF preview, and save/reopen. **Ctrl/⌘+Enter** previews the unsaved source; **Ctrl/⌘+S** saves. Format HTML and field insertion participate in the browser's undo history. Wrap lines changes only the editor view.

Quiet status replaces routine success/advisory toast stacks. PDF notes remain available on demand. Real failures preserve the draft and show one inline explanation with technical details collapsed.

## Implementation and limits

Canvas remains a separate authoring product. The editing sheet approximates HTML layout; native PDF preview is the pagination authority. Saving is explicit. Direct PDF/DOCX drop-to-edit and autosave are not added by this overhaul.

The PDF viewer uses the existing pinned PDF.js 4.7.76 adapter and permission-checked private ContentVersion reader. No public file distribution or outside renderer is created. Preview still uses Apex to read the generated PDF and remains subject to Salesforce platform limits.

See [Designer usability validation](DESIGNER_USABILITY_VALIDATION.md) for live paths, regression results and the unchanged offline-QA baseline. Demo template: `a0DQL00000eWVRR2A4`; preview record: `0Q0QL000005dg1J0AQ`.

## Custom font collection

**Designer Fonts - Test Collection** is a separate inactive HTML template in the same scratch org. It has nine families and 16 approved faces, a live fictional Account name, and a prepared Arabic sample. Choose **Design**, click a word or select text, then **Font family → More fonts…**. The native comparison PDF has two Letter pages and embeds all 16 faces. See [FEATURE_REVIEW.md](FEATURE_REVIEW.md) for the repeatable seed commands, checks and release-validation limits.
