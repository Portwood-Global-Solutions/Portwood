Portwood custom-font demo (Canvas / HTML to native PDF)

Deploy this branch to a scratch org and assign DocGen_Admin.
Run: node scripts/fonts/setup-demo.mjs --target-org YOUR_SCRATCH_ALIAS
Open Portwood > Assets > Fonts. Inspect each current native PDF specimen before approving it.
Run: node scripts/fonts/setup-demo.mjs --target-org YOUR_SCRATCH_ALIAS --create-template
Find Custom Fonts - Brand Showcase under Your Templates; choose Design.
Set an Account sample record through Data. Preview generates a native PDF.

Demo sources under scripts/fonts/fixtures are unmodified Barlow Regular/Bold, Barlow Condensed
ExtraBold, DM Serif Display and Parisienne, with their original SIL OFL licenses. The setup script
uploads them through Salesforce Files. No font Static Resources are required or included.
Apex tests use small, renamed real-outline subsets with the original licenses retained in
DocGenFontTestData; they do not depend on deployed sample font resources.

Custom uploads: upload a static TTF, include its license and confirm public preview/PDF embedding
rights. Inspection runs as Queueable Apex and derives names, style, embedding flags, coverage and
hashes server-side. The original ContentVersion is linked to the font asset without copying bytes.
Generate a native PDF specimen, review its actual face/glyphs, then approve it for Canvas and HTML.
The TTF limit is 9 MiB (9,437,184 bytes); licenses remain limited to 64 KiB.
There is no ZIP, package download, Static Resource deployment or registration step.

The native renderer loads the exact original File version using a shepherd URL with ?font.ttf.
That suffix is required: the plain download URL silently falls back in the native renderer.
Source_Checksum__c pins Salesforce's File checksum to the inspected bytes. Runtime checks the
asset link, exact version, size (when recorded) and checksum using metadata only. It never reads
font VersionData into the generation transaction. A newer File version cannot replace an old
binding. A missing/changed/unlinked original fails clearly. First proof of an older staged revision
checks SHA-256 against the original inspection before pinning its File checksum.

Browser previews use a version-pinned Salesforce Files public delivery link (ContentDistribution).
The same-origin /sfc/dist/version/download path avoids private shepherd cross-domain redirects.
Font bytes are fetched directly into the browser, never through synchronous Apex or LWC JSON.
Only licensed font bytes are shared; PDF specimens, documents and record data are not published.
Public hosting rights remain an explicit upload confirmation. There is no external font host.
Retiring a face removes it from new selections; already-pinned templates retain the same File.

Imports and proof migration use Winter '27's 25 MB asynchronous heap. Older compatibility heap
settings must be disabled before large imports. Inspection remains bounded to 20,000 glyphs/cmap
characters. Static TrueType only; variable, CFF/OTF, WOFF and collections are outside this slice.
Missing glyphs and unavailable styles fail clearly. Browser aliases never replace PDF family names
in saved templates. Built-in-font Unicode repair remains intact outside custom-font scopes.

DOCX font embedding, portable template-bundle font dependency export and automated native proof
approval remain later work. Inline font bindings pin reviewed family/weight/style in the native PDF.
Colour, sizing and layout rules may use !important; authored @font-face is replaced by Assets font tags.

Verification:
node scripts/qa/canvas-custom-font-check.mjs
node scripts/qa/html-font-tags-check.mjs
sf apex run test --target-org YOUR_SCRATCH_ALIAS --tests DocGenFontTest --tests DocGenAssetTest --tests DocGenCanvasSaveTests --tests DocGenHtmlTemplateTest --wait 10
pdffonts specimen.pdf (expect embedded CID TrueType Identity-H)
pdftotext specimen.pdf - (verify live text)
Inspect actual PDF glyph runs, including U+015E/U+015F when covered, and render every page.

HTML font merge tags

After fonts are verified, open Assets > Fonts, choose a face, and click Copy font tag.
Use the tag as an inline style declaration in the HTML source editor:
<p style="{%font:barlow:179138cb809b03a1};font-size:12pt">{Name}</p>

The tag combines an asset key with an immutable font-revision prefix. It always selects the
same face, including its exact weight/style, and never silently follows a new upload.
The full 64-character revision key is also accepted instead of its 16-character prefix.
Use a body/div for inheritance, and a nested tag for another face (including real bold/italic).
Existing pinned tags keep working after retirement; only verified active faces can be copied
for new selections. Missing fonts, ambiguous revisions, unavailable styles and missing glyphs
fail clearly. Font tags are HTML/PDF style declarations, not image URLs or stylesheet macros.

Body-level tags survive HTML extraction in both ordinary and giant-query templates. Tags in
headers/footers work without page counters. A custom-font header/footer containing page-counter
tags fails explicitly because that engine path flattens the section into an unbound CSS string.
Use an unstyled counter footer and a separately styled section for custom fonts.

Demo source: docs/examples/HtmlFontTagsShowcase.html
Create the runnable HTML template (preserves any existing demo):
node scripts/fonts/setup-demo.mjs --target-org YOUR_SCRATCH_ALIAS --create-html-template
Find HTML Fonts - Merge Tag Showcase in Portwood, choose Design, and generate a PDF preview.

Stress validation and compatibility limits

See STRESS_VALIDATION.txt for the 208-case corpus, native PDF evidence, scripts and current
exceptions. Static TTF support does not guarantee every Unicode character or script layout.
Custom-font PDFs reject supplementary characters above U+FFFF; use supported BMP symbols
or images. Arabic/RTL and other complex scripts need preparation. Color fonts render their
single-color outlines, and Assets calls out the palette difference. Filenames can contain spaces,
parentheses and Unicode. Metric tables are checked before native rendering. Catalog display
metadata is projected separately from full glyph coverage; generation retains all validation.

Designer review collection

node scripts/fonts/setup-demo.mjs --target-org YOUR_SCRATCH_ALIAS --manifest scripts/fonts/designer-manifest.json

This seeds 16 OFL faces. Fourteen additions to the current Lato Regular/Bold demo are: Barlow Regular/Bold, Barlow Condensed ExtraBold,
DM Serif Display, Parisienne, Lato Italic, Poppins Regular/Bold/Italic, Crimson Text
Regular/Bold/Italic, DM Mono Regular and Amiri Regular. Combined with the scratch demo's
existing Lato Regular/Bold, there are nine families and 16 faces. The manifest includes
those two existing faces too, so it can seed the full collection in a fresh development org. Each face remains
unavailable to the Designer until its current native specimen has been reviewed and approved.
The seed script requires a development org and never auto-approves specimens. Original TTF
files and copyright/license notices are retained under fixtures, outside managed-package source.
Additional upstream files are pinned to Google Fonts commit 1d0e46c7933245c8180fe83e47917961c913bbdb;
source paths and revision hashes are recorded in designer-manifest.json.
