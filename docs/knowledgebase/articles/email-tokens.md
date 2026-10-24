Signing-email tokens belong to the **Email Templates** editor. They are not the document's Salesforce field-query syntax. Their values are supplied by the type of email being sent.

#### Choose the email before choosing a token

Open **Portwood → Email Templates**, pick the **Brand**, then the email type. The editor offers these insertable tokens for each type:

| Email                   | Editor tokens                                                                                                                                                                                           |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Signature Request       | `{SignerName}`, `{SenderName}`, `{CompanyName}`, `{DocumentTitle}`, `{RoleName}`, `{Message}`, `{ActionButton}`, `{DocumentInfo}`, `{SecurityNote}`, `{SignatureUrl}`, `{ExpirationHours}`, `{LogoUrl}` |
| Signature Reminder      | `{SignerName}`, `{SenderName}`, `{CompanyName}`, `{DocumentTitle}`, `{RoleName}`, `{Message}`, `{ActionButton}`, `{DocumentInfo}`, `{SecurityNote}`, `{SignatureUrl}`, `{ExpirationHours}`, `{LogoUrl}` |
| Email Verification Code | `{VerificationCode}`, `{Pin}`, `{ExpirationMinutes}`, `{CompanyName}`, `{LogoUrl}`                                                                                                                      |
| Signer Completed        | `{SignerName}`, `{RoleName}`, `{RequestId}`, `{CompanyName}`, `{LogoUrl}`                                                                                                                               |
| All Signatures Complete | `{RequestId}`, `{CompanyName}`, `{LogoUrl}`                                                                                                                                                             |
| Signer Declined         | `{SignerName}`, `{RoleName}`, `{Message}`, `{RequestId}`, `{CompanyName}`, `{LogoUrl}`                                                                                                                  |
| Completion Confirmation | `{SignerName}`, `{DocumentTitle}`, `{CompanyName}`, `{LogoUrl}`                                                                                                                                         |

`{CompanyName}`, `{BrandColor}`, and `{LogoUrl}` are resolved through branding. `{Message}` is supplied by the send/template message when that email supports it. Missing or unknown ordinary tokens resolve to empty; a value visible in a generic sample preview is not proof that a production sender supplies it for every email type. In particular, do not assume `{DocumentTitle}` is supplied to every sender-notification type.

Values in HTML bodies are HTML-escaped. Shared assets use the separate `{%asset:asset-key}` syntax to resolve to a public image URL. In an email, write the `<img>` yourself; document asset tags use a different image-embedding path.

#### Understand the widgets

| Widget               | Creates                               | Raw values to use for your own design |
| -------------------- | ------------------------------------- | ------------------------------------- |
| `{ActionButton}`     | Branded Review & Sign button          | `{SignatureUrl}`                      |
| `{DocumentInfo}`     | Document/role callout                 | `{DocumentTitle}`, `{RoleName}`       |
| `{SecurityNote}`     | Expiry note and fallback signing link | `{SignatureUrl}`, `{ExpirationHours}` |
| `{VerificationCode}` | Large verification-code block         | `{Pin}`, `{ExpirationMinutes}`        |

The widget's wording and inline styles are generated. A surrounding wrapper can change spacing, but it does not reliably rename or recolor the widget itself in email clients. Replace the widget with your own HTML when you need different wording. Keep the matching raw tokens so the real link or code is still present.

#### Example: a button with your own label

Use **Full custom HTML** when you want the entire email layout under your control:

```html
<table role="presentation" cellpadding="0" cellspacing="0">
    <tr>
        <td style="background:#193b57;padding:14px 28px;">
            <a href="{SignatureUrl}" style="color:#ffffff;text-decoration:none;font-weight:bold;">
                Review your proposal
            </a>
        </td>
    </tr>
</table>
<p>This link expires in {ExpirationHours} hours.</p>
<p>If the button does not work, open <a href="{SignatureUrl}">{SignatureUrl}</a>.</p>
```

Use this on a request/reminder email that carries a signing URL. A custom verification email instead needs `{Pin}` and `{ExpirationMinutes}`. Never replace the real URL with the website homepage or a sample link from the preview.

#### Message and subject precedence

For supported single-template sends, the send-time custom message wins, then the template's **Default Email Message**, then the generic email wording. A send-time custom subject can also override that send's saved subject. Check packet/bulk sends separately; they use their saved email configuration.

Choose the email type and brand, inspect the live preview, then use **Send Test** to an inbox you control before customer delivery. Public image access and a verified eligible sender remain necessary. The global `DocGenEmailTemplateService.render()` helper renders content; it does not send or invent request-specific tokens.
