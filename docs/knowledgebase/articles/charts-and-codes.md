Add a chart to explain your data, or a QR code or barcode that readers can scan.

#### Make a chart in Canvas

1. Choose **Chart** and click the page.
2. Choose the related list to summarize, such as **Opportunities** on an Account.
3. Choose the field to group by, such as **StageName**.
4. Choose the chart style and size.
5. Preview a record with several matching related records.

If a chart should move with a growing table, give it a name and use the same **Follows** controls as other Canvas blocks.

#### Add a chart to Word or HTML

Use a chart tag. For example, on an Account template:

```text
{Chart:Opportunities:StageName:bar:title=Opportunities by stage}
```

This groups the Account's Opportunities by stage. Use a valid relationship and field for your object. Start with a simple bar chart before adding filters or multiple series.

Chart support depends on the output path. HTML-to-PDF is safest with the supported CSS chart styles: **bar**, **pivot**, **clustered**, and **stacked**. An inline SVG chart visible in an HTML preview can disappear in Salesforce's PDF renderer. Excel output does not embed chart-tag images.

For the complete style and output matrix, use the [chart reference](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/merge-tags.md#76-charts).

#### Add a QR code or barcode

In Canvas, choose **Code**, place it, then set the code type and value in its properties. A value can come from a field so each generated record gets its own code.

For Word or HTML, use the template's copy-paste tag tools or the [barcode reference](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/merge-tags.md#78-barcodes--qr-codes). Match the barcode type to the scanner or business process that will read it.

#### Check the result

Generate the actual output format. Confirm chart labels are legible and totals make sense. Scan printed codes at the size people will actually use; a code that scans at full screen can become unreadable when printed too small.
