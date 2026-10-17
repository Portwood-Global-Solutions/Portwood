# Generate templates with Agentforce — setup

**The setup and usage instructions live in the UserGuide, section 5.7.11.** That
is the version customers read at <https://portwood.dev/guide>, so it is the one
that gets kept current. This file exists only so links in the Apex source have
somewhere to land, and to hold the engineering notes that do not belong in a
customer document.

→ [UserGuide.md § 5.7.11 — Generate the template with Agentforce](../UserGuide.md#5711-generate-the-template-with-agentforce-v346)

## Engineering notes, not for the UserGuide

**Why the provider class cannot ship in the package.** It references
`ConnectApi.EinsteinLLM`, which is not a visible Apex type without the Einstein
entitlement. The package _builds_ fine — with the correct scratch-org recipe the
build org can have Einstein — but **install into a subscriber org without it is
refused**:

```
ApexClass Type is not visible: ConnectApi.EinsteinLLM
Details: DocGenEinsteinProvider: Type is not visible: ConnectApi.EinsteinLLM
```

Buildable is not installable. Both are measured; see
`docs/AGENTFORCE_TEMPLATE_PLAN.md` for the full record.

**Why the prompt template cannot ship either.** Including a
`GenAiPromptTemplate` makes the whole package declare a feature requirement, so
every subscriber without Einstein is refused at install:

```
Generative AI Prompt Templates(...) Missing feature — Installing this package
requires the following feature and its associated permissions: Generative AI
Prompt Templates
```

That is worse than the Apex case: it gates the entire product, not one class.

**Why there is no "install the prompt for me" button.** The mechanism exists —
`GenAiPromptTemplate` is absent from the Tooling API and from the Apex Metadata
API, but a self-callout to `/services/data/vXX/metadata/deployRequest` does
deploy it (proven end to end). It is unusable in practice because it requires
`UserInfo.getSessionId()`, which is an immediate AppExchange security-review
failure for a managed package.

**The route that remains open** is an extension package: a separate
Einstein-requiring package carrying the provider class and the prompt template.
The base package needs no change — `DocGenAiProviderFactory` already resolves
the provider in the subscriber namespace first, then in `portwoodglobal`.

## Reference authoring in this feature branch

The base wizard offers Existing template, Designer / Canvas, and Generate with AI.
AI drafts open in the flowing HTML Designer; Canvas remains a separate editor and
storage format. `buildAiPrompt()` is shared by create and edit, ends with the user
brief, and includes only approved font revisions and the queried schema.

The updated extension contains `DocGen_Query_Plan`, `DocGen_Query_Reference`,
`DocGen_HTML_Reference` and `DocGen_HTML_Body`. Activate all four in Prompt Builder.
These feature-branch additions are deployed to the demo scratch org, not released.
The source uses GPT 5.4, which was exercised with
plain instructions, a native PDF input, and prepared DOCX. The demo trial has zero
Advanced-model allowance; GPT 5.5 returned `LLM_GATEKEEPER E90000` / HTTP 429.
Choose a stronger entitled model when available, retaining PDF support for the
reference template. Provider presence indicates a callable integration, not proof
of available model credits; generation errors surface the actual platform reason.

The record-based AI entry does not call `_buildDefaultQueryConfig` or require an
object/field picker. `docGenAiConversation` sends the customer's conversation to
`DocGenAiQueryPlanner.converse`. The provider's optional Callable `planQuery`
action returns one of `schema`, `ask`, or `ready`. Schema requests search real
readable/queryable objects and inspect paged fields, picklists, parent references
and child relationships. Each schema hop is a separate Apex transaction. The
model can ask a business question, then revise the plan from a natural reply.

Ready plans use a structured filter tree and sort list, not executable model
SOQL. The planner validates readable fields and relationship links, escapes typed
literals and compiles each node with a USER_MODE `WHERE Id = null` probe. Invalid
plans return repair evidence to Agentforce. The existing V3 record-scoped query
configuration is saved only after validation; no default date window or row limit
is imposed. Planning does not retrieve customer record values. Generation and
preview use the existing data retriever. Salesforce governor limits still apply.

The UI shows a plain-language plan; generated query JSON is optional advanced
detail. Unsent replies, changed references and pending planning invalidate the
ready state. The approved query shape plus accumulated customer requests then
feed HTML generation. Existing Designer AI edits keep their existing query.

`queryPlanning` is an optional Callable capability; the shipped global provider
interface is unchanged. Older extensions explain the upgrade needed for the new
conversation. Flow JSON and manual Designer/Canvas routes retain their own data
setup. The shared HTML prompt now distinguishes keeping rows together from
keeping short cell values on one line, and covers repeated table headings,
column widths, oversized rows, once-only totals and intentional page breaks.

The reference Flex template has `Instructions` (String) and `ExampleFile`
(ContentDocument). The metadata input URI is case-sensitive:
`SOBJECT://ContentDocument`. Pass `Input:ExampleFile` as a WrappedValue whose value
is `{ 'id' => contentDocumentId }`. No file bytes pass through Aura. Salesforce's
native reference budget is 15 MB; this UI accepts one PDF or DOCX. Salesforce
handles the configured model, including its separate binary-file data policies.

DOCX preparation runs as a Queueable, uses native Compression and DocGen's Word
renderer, and reads customer Files in USER_MODE. It extracts main-body PNG/JPEG
images into private Files and carries record-scoped viewer links to the created
template. It does not create ContentDistribution/public links. Let Salesforce
choose record-link Visibility: explicitly assigning InternalUsers fails in orgs
without Experience Cloud. Status polling checks the job's creator and Apex class;
result file titles normalize 15/18-character job IDs. Expanded HTML is limited by
the authoring prompt budget; processing failures recommend a smaller example or
PDF export. Header/footer images, drawings, macros, tracked changes, and complex
Word layouts are not promised as faithful conversion.

The existing global DocGenAiProvider interface is unchanged. Native file support
uses an optional global Callable capability. Older extensions and custom providers
can keep generating from text and prepared DOCX; native PDF references explain
when the updated extension is required. The base package contains no Einstein Apex
type or GenAiPromptTemplate metadata dependency.

Native rendering remains the review gate. The demo exposed a duplicated positive
`.records` wrapper around a row loop; generation now rejects that specific pattern.
The shared HTML merge engine also keeps scalar truthy sections inline so a
Description conditional within a repeating row cannot consume sibling cells.
Neither validation nor the prompt proves commercial wording or amounts are right;
review the native Quote PDF against saved Salesforce totals before sharing.
