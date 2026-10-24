Print a value and make it readable. These tags work with fields selected for the template, or keys supplied by your own data provider.

**Before you start:** Choose the fields and relationships in [Choose information](#choose-data). For an orientation and the format checklist, open [Find the right merge tag](#merge-tags).

#### Field merge

```
{FieldName}
{!FieldName}              Salesforce-style prefix — treated identically to {FieldName}
{Account.Name}            Parent lookup
{Owner.Profile.Name}      Multi-level lookup (any depth)
```

Null/missing fields render as empty string — no error, no placeholder.

Tag names are case-sensitive, and there's **no escape or comment syntax** — any `{…}` pair is treated as a tag (an unknown name resolves to empty string, so `{like this}` silently disappears), and an unclosed `{` fails the merge with a "Malformed merge tag" error. If a document needs literal braces: in HTML templates use the entities `&#123;` and `&#125;`; in Word templates avoid brace-wrapped prose.

#### Format specifiers

Append `:format` to a field tag.

#### Date formatting

```
{CloseDate:MM/dd/yyyy}          Java SimpleDateFormat pattern
{CloseDate:MMMM d, yyyy}        April 17, 2026
{CloseDate:date}                User's locale default
{CloseDate:date:de_DE}          17.04.2026 (German)
{CloseDate:date:ja_JP}          2026/04/17 (Japanese)
{CloseDate:date:en_GB}          17/04/2026 (British)
```

Locale defaults: `en_US` → `MM/dd/yyyy`; `en_GB/AU/NZ/IE/IN` → `dd/MM/yyyy`; `de_*`, `ru_*`, `pl_*`, `cs_*`, `hu_*`, `tr_*` → `dd.MM.yyyy`; `fr_*`, `es_*`, `it_*`, `pt_*` → `dd/MM/yyyy`; `nl_*` → `dd-MM-yyyy`; `ja_*` → `yyyy/MM/dd`; `zh_*` and Nordic → `yyyy-MM-dd`; `ko_*` → `yyyy. MM. dd`.

#### Currency formatting

```
{Amount:currency}               $500,000.00 (US default)
{Amount:currency:EUR}           €500,000.00
{Amount:currency:EUR:de_DE}     500.000,00 € (German formatting)
{Amount:currency:JPY}           ¥500000 (no decimals)
{Amount:currency:GBP}           £500,000.00
```

Supported currencies: USD, EUR, GBP, JPY, CNY, CHF, CAD, AUD, INR, KRW, BRL, MXN, SEK, NOK, DKK, PLN, CZK, HUF, TRY, ZAR, SGD, HKD, NZD, THB, MYR, PHP, IDR, TWD, ILS, RUB, NGN, KES, AED, SAR, COP, CLP, PEN, ARS, EGP, GHS, ISK, VND.

Zero-decimal currencies (JPY, KRW, CLP, VND, HUF, ISK, TWD) format without decimals automatically.

##### Auto-detecting the currency from the record

Use `:currency:auto` when the symbol should follow the **record's own currency** rather than a fixed ISO code — ideal for multi-currency orgs.

```
{Amount:currency:auto}                       Reads the standard CurrencyIsoCode field
{Amount:currency:auto=CustomerCurrency__c}   Reads a named currency field (e.g. an ERP field)
{Amount:currency:auto:en_GB}                 auto + an explicit locale for separators/placement
{Amount:currency:auto=CustomerCurrency__c:de_DE}
```

How it works and what to know:

- **The source field must hold an ISO 4217 code** (`GBP`, `USD`, `EUR`, …) — its value is matched against the supported-currency list above.
- **List the source field in your template's Query Config.** Portwood builds its query from the Query Config (it does not scan the template body), so a field referenced only inside `:currency:auto=...` must be added to the Query Config like any other merge field. The standard `CurrencyIsoCode` is added automatically in multi-currency orgs, so bare `:currency:auto` works without listing it.
- **Safe fallback:** if the source field is missing, blank, or not a recognized ISO code, the tag falls back to the default `$` format — it never errors or prints a raw code.
- **Bare `:currency` is unchanged** — it always emits `$`. Auto-detection is strictly opt-in via `:auto`.
- **Aggregates** support it too: `{SUM:Lines.Amount:currency:auto=CustomerCurrency__c}` uses the **parent** record's currency for the symbol.

##### Totalling across currencies

In a multi-currency org, the rows behind an aggregate can each carry their own currency. Adding them together and stamping one symbol on the result produces a number that looks authoritative and is meaningless — so Portwood won't do it silently.

```
{SUM:Lines.Amount:currency:EUR}            Mixed-currency rows → generation fails with a clear error
{SUM:Lines.Amount:currency:EUR:convert}    Every row converted to EUR first, then summed
{SUM:Lines.Amount:currency:auto:convert}   Converts into the parent record's own currency
{SUM:Lines.Amount:currency:EUR:de_DE:convert}   convert always goes last, after any locale
```

What to know:

- **The guard only fires when there's a real conflict** — two or more different currency codes among the rows being aggregated. One currency, or rows with no currency code at all, behave exactly as they always have.
- **Append `:convert` to any aggregate** (`SUM`, `AVG`, `MIN`, `MAX`) to convert first. `MIN`/`MAX` compare converted amounts, so the smallest _number_ isn't mistaken for the smallest _amount_.
- **Rates come from Setup → Manage Currencies** (`CurrencyType`), pivoting through your corporate currency. If a rate is missing, the tag fails with an actionable message rather than quietly returning an unconverted number.
- **Advanced Currency Management dated rates are not used** — conversion applies your current static rate. See issue #273.
- **Single-currency orgs are entirely unaffected.** None of this engages.
- **Without `:convert`, nothing converts.** `{SUM:Lines.Amount:currency:EUR}` over EUR-only rows formats them as euros; it does not translate other currencies into euros.
- **Beyond aggregates: `:convert` works on a plain currency field too (v3.57+).** `{Amount:currency:EUR:convert}` converts the record's own amount from its `CurrencyIsoCode` into the target ISO before formatting, and composes with locale (`:EUR:de_DE:convert`) and `auto`. A record with no source currency passes through unconverted; a missing rate raises the same "add it under Manage Currencies" error as above.

#### Number formatting

```
{Quantity:number}               1,234 (US separators)
{Quantity:number:de_DE}         1.234 (German — dot-as-thousands)
{Quantity:number:fr_FR}         1 234 (French — space-as-thousands)
{Quantity:#,##0}                Custom pattern — always US separators
{Quantity:#,##0.00}             1,234.56
{Quantity:0,000}                Custom pattern with leading zeros
```

#### Percent formatting

```
{Rate:percent}                  15.5%
{Rate:percent:de_DE}            15,5 %
```

#### Checkbox formatting

```
{IsActive:checkbox}             [X] when true, [ ] when false
```

Uses ASCII box-drawing characters — works in any font.

#### Picklist label formatting

```
{Status__c}                     Stored API value
{Status__c:label}               User-facing picklist label
```

Use `:label` when a picklist stores integration-friendly API codes but the document should show the label users see in Salesforce.

#### Built-in date/time tags

Two special merge tags resolve to the current date/time without needing a formula field. They accept the same format suffixes as any date field:

```
{Today}                         2026-04-20 00:00:00 (bare tag carries a midnight time — add a format suffix for a clean date)
{Today:MM/dd/yyyy}              04/20/2026
{Today:MMMM d, yyyy}            April 20, 2026
{Today:date}                    Running user's locale default
{Today:date:de_DE}              20.04.2026 (German)
{Now}                           2026-04-20 14:30:00 (current DateTime)
{Now:yyyy-MM-dd HH:mm}          2026-04-20 14:30
{Now:date:ja_JP}                2026/04/20 (Now formatted as Japanese date)
```

Case-insensitive for the keyword itself (`{today}` works). Works in sync, giant-query, bulk, and signature-stamped documents. All format suffixes from §7.2 apply.

#### Running user tags (Prepared by:)

`{RunningUser.X}` resolves against the **executing user's** record (whoever clicks Generate, runs the Flow, or owns the bulk job). No configuration — works on every template, every record, every output format.

```
Prepared by: {RunningUser.Name}
Email:       {RunningUser.Email}
Title:       {RunningUser.Title} · {RunningUser.Department}
Phone:       {RunningUser.Phone}
```

**Allowlist** — these are the only User fields exposed (other field names resolve to empty by design, so signed templates can't be edited to leak arbitrary User columns):

| Group     | Fields                                                              |
| --------- | ------------------------------------------------------------------- |
| Identity  | `Id`, `Name`, `FirstName`, `LastName`, `Email`, `Username`, `Alias` |
| Title/org | `Title`, `Department`, `CompanyName`, `EmployeeNumber`              |
| Contact   | `Phone`, `MobilePhone`, `Extension`, `Fax`                          |
| Address   | `Street`, `City`, `State`, `PostalCode`, `Country`                  |
| Locale    | `TimeZoneSidKey`, `LocaleSidKey`, `LanguageLocaleKey`               |

Case-insensitive for the namespace (`{runninguser.name}` works). Format suffixes from §7.2 apply: `{RunningUser.Phone}`, `{RunningUser.Name:!}` (no formatter needed for strings — most useful for date-typed extensions).

Works in sync generation, bulk runs, giant-query PDFs (headers/footers/title blocks), Flow-triggered docs, and HTML templates. The User row is queried **once per transaction** and cached, so a 60K-row PDF with `{RunningUser.Name}` in the header costs one extra SOQL total.

#### Checkmarks & symbols (PDF-safe)

Salesforce's PDF engine (Flying Saucer) only ships with four fonts (Helvetica, Times, Courier, Arial Unicode MS) and does not render arbitrary Wingdings or Symbol glyphs. Approved custom static TrueType faces are supported through **Assets → Custom Fonts**. Most "decorative" Word symbols (Wingdings checkboxes, custom dingbats) silently render as a blank box.

Portwood handles this for you in two ways:

1. **Word checkbox glyphs** (Insert → Symbol → Wingdings 0xFE / 0xA8, or Word content-control checkboxes) are auto-translated to their Unicode equivalents at PDF render time.
2. **Unicode symbols** typed directly in Word, Google Docs, Notion, or any HTML template are auto-wrapped in an Arial Unicode MS span so they render instead of dropping to tofu.

#### Copy-paste symbol palette

These all render reliably in PDF and DOCX. Highlight + copy any of them into your template:

**Checkboxes**
| Symbol | Name | Codepoint |
|---|---|---|
| ☐ | Empty checkbox | U+2610 |
| ☑ | Checked checkbox | U+2611 |
| ☒ | Crossed checkbox | U+2612 |

**Checks & crosses**
| Symbol | Name | Codepoint |
|---|---|---|
| ✓ | Check mark | U+2713 |
| ✔ | Heavy check mark | U+2714 |
| ✗ | Ballot X | U+2717 |
| ✘ | Heavy ballot X | U+2718 |

**Bullets & arrows**
| Symbol | Name | Codepoint |
|---|---|---|
| • | Bullet | U+2022 |
| ▪ | Black square | U+25AA |
| ▶ | Right-pointing triangle | U+25B6 |
| ► | Right-pointing pointer | U+25BA |
| → | Right arrow | U+2192 |
| ← | Left arrow | U+2190 |
| ↑ | Up arrow | U+2191 |
| ↓ | Down arrow | U+2193 |
| ⇒ | Heavy right arrow | U+21D2 |

**Stars & rating**
| Symbol | Name | Codepoint |
|---|---|---|
| ★ | Filled star | U+2605 |
| ☆ | Empty star | U+2606 |
| ♥ | Heart | U+2665 |
| ♦ | Diamond | U+2666 |

**Punctuation & misc**
| Symbol | Name | Codepoint |
|---|---|---|
| § | Section | U+00A7 |
| ¶ | Pilcrow | U+00B6 |
| † | Dagger | U+2020 |
| ‡ | Double dagger | U+2021 |
| … | Ellipsis | U+2026 |
| — | Em dash | U+2014 |
| – | En dash | U+2013 |
| © | Copyright | U+00A9 |
| ® | Registered | U+00AE |
| ™ | Trademark | U+2122 |
| ° | Degree | U+00B0 |
| ± | Plus-minus | U+00B1 |
| × | Multiplication | U+00D7 |
| ÷ | Division | U+00F7 |

#### Conditional checkbox pattern

Combine the checkbox glyphs with `{Field:checkbox}`, or use `{#IF}` with `{:else}` to render dynamic checked/unchecked state from a Salesforce checkbox field:

```
Approved: {#IF IsApproved}☑{:else}☐{/IF}
```

Or in tabular form for surveys / inspection forms (the inverse section `{^Field}` works too):

| Item             | Status                                                              |
| ---------------- | ------------------------------------------------------------------- |
| Pre-flight check | {#IF Preflight_Complete\_\_c}☑{:else}☐{/IF}                         |
| Safety briefing  | {#IF Safety_Done\_\_c}☑{/IF}{^Safety_Done\_\_c}☐{/Safety_Done\_\_c} |

> There is no `{#IFNOT}` tag — use `{:else}` inside an `{#IF}`, or the inverse section `{^Field}…{/Field}` (§7.4).

#### What does NOT work

- **Wingdings / Webdings glyphs** other than checkboxes — Flying Saucer can't render them at all. Portwood translates the common checkbox/check codepoints (Wingdings F0A8, F0FE, F0FD, F0FB, F0FC, F0A2; Wingdings 2 F050–F053, F0A3, F0A4); anything else falls back to a neutral □ placeholder.
- **Emoji** (😀 🎉 etc.) — out of Arial Unicode MS coverage, render as tofu in PDF. Use the Unicode symbols above instead.
- **Unapproved or unsupported fonts** — use an approved static TrueType face for PDF, or native DOCX output where the recipient has the font installed. See [custom fonts](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#custom-fonts).
