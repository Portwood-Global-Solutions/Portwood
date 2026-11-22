Use a simple page-number tag for a simple footer. Use CSS counters when you need page numbers alongside multiple formatted lines, logos, or other HTML.

#### The simple footer

In **Footer HTML**, enter:

```html
Page {PageNumber} of {TotalPages}
```

In the current engine, literal `{PageNumber}` or `{TotalPages}` in a header/footer selects a text-based page-margin path. The engine converts that HTML to text, so separate lines, images, and rich formatting can flatten. That explains a footer that looks right in the editor but loses its layout in the PDF.

#### The rich footer

1. Put these rules inside the main template body's `<head><style>…</style></head>`.
2. Put the following HTML in the template's **Footer HTML** field.
3. Keep literal `{PageNumber}` and `{TotalPages}` out of that header/footer.
4. Save a new active version and generate a multi-page PDF.

```css
.pw-page-number:before {
    content: counter(page);
}
.pw-total-pages:before {
    content: counter(pages);
}
```

```html
<div style="text-align:center;font-family:Helvetica,Arial,sans-serif;line-height:1.3;">
    <div style="font-size:9pt;">Page <span class="pw-page-number"></span> of <span class="pw-total-pages"></span></div>
    <div style="font-size:7pt;color:#7d7d7d;">Northstar Bikes | 317-555-0142 | hello@example.com</div>
</div>
```

With this setup, Portwood repeats your formatted footer and CSS supplies the page numbers. Generate a document long enough to cross a page. Keep both footer lines visible and check that `Page 1 of 4` advances all the way to `Page 4 of 4` in a four-page file.

#### Make room for it

Set enough top/bottom margin for the actual logo, line height, and number of lines. Choose one owner for page size and margins. Imported `@page` rules, the designer's page setup, and header/footer controls can otherwise compete.

Keep counters in page furniture. These are PDF layout counters, not record fields or row numbers. A packet assembled from separately rendered PDFs can retain numbering from each original document; test whether that meets your requirement for the final packet.

#### When something still looks wrong

| Symptom                               | Check                                                                            |
| ------------------------------------- | -------------------------------------------------------------------------------- |
| Everything becomes one line           | Remove literal page-number tags from that header/footer and use counter spans    |
| Footer overlaps the body              | Increase the bottom margin and reduce oversized content                          |
| Page number is blank                  | Keep the CSS in the main body stylesheet; verify exact class names and final PDF |
| Custom font and literal counters fail | Use running HTML plus CSS counters and test the approved font specimen           |
| Header image is missing               | Confirm image access and dimensions in the actual render path                    |

This recipe adapts Dave's [two-line footer answer in Portwood Community](https://portwoodcommunity.slack.com/archives/C0B37JT11RA/p1792162191491549). You can compare the layout with the [finished service schedule](#css-print-lab).
