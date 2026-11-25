# Portwood HTML template recipes

Use these as small authoring patterns when authoring an HTML template for Salesforce PDF output. Keep the HTML simple, use the exact field API names from the template query, and verify the generated PDF in the target org. For the full renderer rules and reusable LLM prompt, see [HTML and Word layout](template-layout.md).

Start with the [one-field letter](../knowledgebase/examples/acceptance/account-letter.html). For a full working example, use the [service schedule](../knowledgebase/examples/acceptance/service-review.html) and its [rendered PDF](../knowledgebase/examples/acceptance/service-review.pdf).

## Two-column header

Use a table for side-by-side content. Fixed widths and cell padding are more predictable than flexbox or grid.

```html
<table style="width: 100%; border-collapse: collapse;">
    <tr>
        <td style="width: 62%; vertical-align: top;">
            <strong>{Account.Name}</strong><br />
            {Account.BillingStreet}<br />
            {Account.BillingCity}, {Account.BillingState} {Account.BillingPostalCode}
        </td>
        <td style="width: 38%; text-align: right; vertical-align: top;">
            Quote {Name}<br />
            Prepared {Today:MMMM d, yyyy}<br />
            {RunningUser.Name}
        </td>
    </tr>
</table>
```

## Repeating line items with totals

Put the opening and closing loop tags inside the first and last cells of the repeating row. The table header stays in place while the data row repeats.

```html
<table style="width: 100%; border-collapse: collapse;">
    <tr style="background-color: #eaf2fb;">
        <th style="text-align: left; padding: 6pt;">Item</th>
        <th style="text-align: right; padding: 6pt;">Qty</th>
        <th style="text-align: right; padding: 6pt;">Price</th>
        <th style="text-align: right; padding: 6pt;">Total</th>
    </tr>
    <tr>
        <td style="padding: 6pt;">{#OpportunityLineItems}{Product2.Name}</td>
        <td style="text-align: right; padding: 6pt;">{Quantity}</td>
        <td style="text-align: right; padding: 6pt;">{UnitPrice:currency}</td>
        <td style="text-align: right; padding: 6pt;">{TotalPrice:currency}{/OpportunityLineItems}</td>
    </tr>
</table>
<p style="text-align: right; font-size: 14pt; font-weight: bold;">
    Total: {Amount:currency}
</p>
```

For a row number, place `{RowNumber}` inside the loop. For nested child rows, use the relationship names from the query and keep each loop balanced. Do not wrap a whole `<tr>` with loop tags outside the row.

## Optional clause with a fallback

Use the field conditional when a section should disappear for blank or false values. Use a translated Custom Label for reusable wording that administrators maintain in Salesforce.

```html
<p>{#Special_Terms__c}Special terms: {Special_Terms__c}{:else}Standard terms apply.{/Special_Terms__c}</p>
<p>{!$Label.Payment_Terms}</p>
```

The label uses the running user's Salesforce language. The field used by the conditional and its value must be in the template's selected data.

## Reusable terms and approved fonts

Save a reusable section under **Portwood → Assets → Terms & snippets**, then insert the copied tag where it should appear:

```html
<div>{%snippet:terms-and-conditions}</div>
```

The snippet itself can contain fields. Save `<p>Prepared for <strong>{Name}</strong>.</p>` in **HTML source**. Include **Name** in your Account template, then insert the copied snippet tag. For an Account named Alder Works, the PDF reads **Prepared for Alder Works.** Inside a Contacts loop, the same field reads the current Contact’s name when **Contacts → Name** is selected. [Follow the snippet exercise](../../UserGuide.md#shared-content)

Use the stable API name of an approved custom font. Copy the exact tag from the Custom Fonts area; do not guess a font key or revision:

```html
<p style="{%font:brand-sans-bold};font-size:12pt;color:#193b57;">Prepared for {Account.Name}</p>
```

Snippets are body fragments, not complete HTML documents. Add page-wide CSS in the parent template. Test office output separately; recipients may need the font installed in their Office application.

## QR code and barcode

Portwood generates these images natively. Use a short, scannable value for printed QR codes.

```html
<table style="width: 100%;">
    <tr>
        <td>Order: {OrderNumber}</td>
        <td style="text-align: right;">{*TrackingUrl:qr:150}</td>
    </tr>
    <tr>
        <td colspan="2">{*ProductCode:code128:300x80}</td>
    </tr>
</table>
```

Only the supported `qr` and `code128` types render. QR values up to 600 characters are accepted; short URLs and tokens under 120 characters scan more reliably at print size.

## HTML-safe chart patterns

For HTML-to-PDF, choose chart styles that render as CSS bars or a table. Inline SVG chart output is suitable for browser HTML but disappears in the Flying Saucer PDF renderer.

```html
<h2>Responses by answer</h2>
{Chart:Survey_Responses__r:Selected_Answer__c}

<h2>Department cross-tab</h2>
{Chart:Survey_Responses__r:Selected_Answer__c:pivot:groupBy=Department__c&colSort=Sales,Service&title=Responses by department}
```

Where an entry point supplies a prepared chart PNG, HTML-to-PDF can also display pie, donut, column, line or area charts. Without that PNG the HTML expander supports bar, pivot, clustered and stacked for PDF. Pivot, clustered and stacked require a second selected field in `groupBy=` and a list of column values in `colSort=`. Replace Sales and Service with values from your own records. See the [chart reference](merge-tags.md) and the included survey examples before composing modifiers.

## Signature lines

Paste this table directly into the HTML template and assign the signer the **Customer** role when creating the request. You can put a shared clause immediately above the table with its snippet tag. Portwood discovers the signing fields in the main template before it expands the clause. [Example with shared wording](../../UserGuide.md#shared-content)

```html
<table style="width: 100%; margin-top: 24pt;">
    <tr>
        <td style="width: 60%; border-bottom: 1px solid #445; padding: 18pt 4pt 4pt;">
            {@Signature_Customer:1:Full}
        </td>
        <td style="width: 40%; border-bottom: 1px solid #445; padding: 18pt 4pt 4pt;">
            {@Signature_Customer:1:Date}
        </td>
    </tr>
</table>
```

Use the Signature Sender to prepare uploaded PDFs that do not contain Portwood signature tags. Do not invent signature-role names; match the template's signer setup.

## Page footer

Set the template's header or footer HTML and place page counters there. They are not general-purpose body tags.

```html
<div style="text-align: center; font-size: 8pt; color: #555;">
    {Account.Name} · Page {PageNumber} of {TotalPages}
</div>
```

## Large related lists

When the child query exceeds the giant-query threshold, keep the outer shell limited to supported parent-level tags and put the long list in the giant-query table. Do not rely on nested child loops, conditions, barcode tags, form fields, or signature tags in the outer shell. For large table rendering, review [repeat table headers](../knowledgebase/articles/repeat-table-headers.md) and [engine tuning](../knowledgebase/articles/engine-tuning.md).

## Adapt a finished design

The [design studio](../knowledgebase/articles/document-studio.md) includes complete HTML, JSON, generated PDFs and text editions. Use the [quote](../knowledgebase/articles/cpq-quote.md) for two levels of pricing, the [contents and watermark](../knowledgebase/articles/print-navigation.md) for long proposals, the [renewal brief](../knowledgebase/articles/renewal-decision.md) for missing-data decisions, and the [field work order](../knowledgebase/articles/service-sheet.md) for offline labels. The [event-driven signing example](../knowledgebase/articles/event-signing-journey.md) shows how a Screen Flow opens the signer’s page and checks for the finished File.
