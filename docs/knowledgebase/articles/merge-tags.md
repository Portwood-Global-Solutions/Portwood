A merge tag is a small instruction inside braces. Portwood replaces `{Name}` with a name, repeats a row for `{#Contacts}`, or draws a chart for `{Chart:...}`. You can build a useful document with just fields and a loop; the rest are here when you need them.

#### Find the tags for your own Salesforce data

1. Open your template and its **Data** or query-builder controls.
2. Select the base record, fields, parent fields, and related lists the document needs.
3. Copy the exact field path or relationship alias into the template.
4. Pick a sample record that actually has those values and related records.
5. Preview, then generate the final output format.

There is no single fixed list of every Salesforce field tag. Your org supplies standard fields, custom fields, namespaced fields, and relationship names. Query selection supplies the values. A typed tag alone does not add its field to the query. A custom provider or JSON input supplies its own map keys instead.

![Data controls show fields selected for the sample Account](docs/images/userguide/v3.60/choose-data.png)

#### Tag directory

| I want to…                                                                 | Start with                                                           | Full instructions                                          |
| -------------------------------------------------------------------------- | -------------------------------------------------------------------- | ---------------------------------------------------------- | --------------------------------------------- |
| Print a field or a parent record value                                     | `{Name}`, `{Account.Name}`                                           | [Fields and formatting](#tag-fields)                       |
| Format money, numbers, dates, percent, checkbox, or picklist labels        | `{Amount:currency}`, `{CloseDate:MMMM d, yyyy}`, `{StageName:label}` | [Fields and formatting](#tag-fields)                       |
| Print today's date, the current time, or the person preparing the document | `{Today}`, `{Now}`, `{RunningUser.Name}`                             | [Built-in and user tags](#tag-fields)                      |
| Repeat one row per related record                                          | `{#Contacts}…{/Contacts}`                                            | [Loops](#tag-loops)                                        |
| Number rows, group by a field, or use root data from inside a loop         | `{RowNumber}`, `{#GroupBy … by …}`, `{~Root}…{/Root}`                | [Grouping and scope](#tag-loops)                           |
| Show optional content or one of two messages                               | `{#IF Amount > 10000}…{:else}…{/IF}`                                 | [Conditions](#tag-conditions)                              |
| Count or total related records                                             | `{COUNT:Contacts}`, `{SUM:Opportunities.Amount:currency}`            | [Totals](#tag-totals)                                      |
| Add a chart                                                                | `{Chart:Opportunities:StageName:donut}`                              | [Charts and options](#tag-charts)                          |
| Add an image, asset, barcode, or QR code                                   | `{%LogoUrl}`, `{%asset:company-logo}`, `{*Website:qr:200}`           | [Images and codes](#tag-media)                             |
| Place a signature or initials for a role                                   | `{@Signature_Buyer}`, `{@Signature_Buyer:1:Initials}`                | [Signature tags](#tag-signatures)                          |
| Print classic approvals                                                    | `{#Approvals}…{/Approvals}`                                          | [Approval history](#tag-approvals)                         |
| Repeat a Word table header                                                 | `{RepeatHeader}` in the header row                                   | [Repeating table headers](#repeat-table-headers)           |
| Number PDF pages                                                           | `{PageNumber}`, `{TotalPages}` in Header/Footer HTML                 | [Page headers and footers](#running-headers-footers)       |
| Collect an answer from the signer                                          | `{?poNumber}`, `{?poNumber                                           | N/A}`                                                      | [Signer inputs and writeback](#signer-inputs) |
| Customize a signing email                                                  | `{SignerName}`, `{SignatureUrl}`, `{VerificationCode}`               | [Email tokens by type](#email-tokens)                      |
| Use an approved custom PDF font                                            | `{%font:asset-key:revision}` inside `style`                          | [Font tags](#tag-media) and [font approval](#custom-fonts) |

#### Check the output path

| Output                | What to check before you commit to it                                                               |
| --------------------- | --------------------------------------------------------------------------------------------------- |
| HTML or Canvas to PDF | CSS 2.1 and paged rendering, table growth, actual page breaks, fonts, images, header/footer margins |
| Word to Word          | Keep each tag together; use real table rows for repeated records; check the finished DOCX in Word   |
| Word to PDF           | Word layout is converted; inspect widths, headers, section breaks, and the resulting PDF            |
| Excel                 | Native XLSX output; chart-image tags are currently unsupported; test loop placement in the workbook |
| PowerPoint            | Native PPTX output; PDF output is unsupported; inspect the populated slides                         |
| Fillable PDF          | Map actual form fields; this is a separate field-mapping workflow, not an HTML layout engine        |

See [Choose a template format](#choose-format) and the [chart output matrix](#tag-charts) for more detail.

#### When a tag is blank or remains on the page

Check its spelling and case, confirm its field is selected, confirm its current loop scope, and check the sample record. A missing value can legitimately be empty. An unclosed brace or mismatched block can stop generation. If you need literal braces in HTML prose, use `&#123;` and `&#125;`.

Email-template tokens such as `{SignerName}` belong to the signing email editor. They are a separate token list; use [Signing email tokens](#email-tokens) for the complete list.
