Set the paper, margins, repeated page content, and page background.

#### Choose paper and margins

- **Canvas:** Open **Page**. Choose the paper size, orientation, and margins there.
- **HTML designer:** Use page setup and check any `@page` rules in imported HTML.
- **Word:** Set page size and margins in Word, then check the generated PDF.

Canvas and HTML can carry their own page rules. Changing a template record's paper setting may not replace a page rule already in its body.

#### Add a header or footer

Use the template's **Header HTML** and **Footer HTML** fields or the designer's **Header/Footer** panel. Put repeating company details in these areas rather than copying them onto each page.

Leave enough margin for the content. An oversized logo can collide with the document even when the logo itself looks fine.

#### Number the pages

Use the supported header/footer tags:

```text
Page {PageNumber} of {TotalPages}
```

Keep page-number tags in the Header/Footer HTML fields, where page numbering is supported. They are different from a field such as `{AccountNumber}`.

#### Add a watermark or background

1. Save the template at least once.
2. Open **Watermark / Background** in the template editor.
3. Upload a correctly sized image.
4. Choose **Light**, **Medium**, **Strong**, or **Original** strength.
5. Generate a PDF and confirm the text remains readable.

For a Letter page, use **816 × 1056 pixels** at 96 DPI. For A4, use **794 × 1123 pixels**; for Legal, **816 × 1344 pixels**.

Use a picture for a text watermark such as DRAFT. Word's text-watermark and rotation settings do not reliably carry into PDF; a pre-rendered image is easier to control.

#### Check more than the first page

Use a record with long text and many table rows. Inspect headers, footers, the last row of a page, blank space, and the last page. In Word, section breaks and different-first-page settings can also affect the PDF.

For troubleshooting widths, AutoFit, and HTML styling, use the [layout reference](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/template-layout.md).
