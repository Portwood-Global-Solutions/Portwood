# Authenticated PDF download reference

This standalone Salesforce DX project reproduces the downloader independently of the bulk generation or browser PDF merger. Its Visualforce page reads a sealed revision with the current Salesforce session and saves it through Chrome or Edge. The fixture and verifier use an existing Salesforce CLI login for a separately authorized scratch org.

## Included components

| Component | Responsibility |
| --- | --- |
| `PortwoodPdfDownload.page` and `PortwoodPdfDownloadController` | Authenticated bounded reads, ordered delivery, and browser-managed disk staging. The page can resume an interrupted download. |
| `ApexPdfRangeRest` and `ApexPdfAppendManifest` | Reads pinned private chunks through Visualforce remoting or a `206 Partial Content` endpoint. A single response is limited to 512 KiB. |
| `PortwoodPdfReadyNotification` and `Portwood_Pdf_Ready` | Sends a Lightning notification to the requesting user after validation of the download revision. The landing page stays behind Salesforce login. |
| `PortwoodPdfArchiveStore` and `PortwoodPdfArchive__c` | Optional owner-only data-record backing store used when scratch File storage filled. This isolated copy omits source-image loading and generator reporting. |
| `PortwoodPdfDownload` permission set | Grants the prototype’s Visualforce page and controller access, plus the permission used for its optional custom notification. |
| `ApexPdfRangeRestTest` and `PortwoodPdfReadyNotificationTest` | Test cross-chunk reads, exact bounds, File and archive ownership, mixed backing-store rejection, and notification target validation. |

The `evidence/downloader.json` file contains sanitized measurements from the original scratch experiments. The 256.93 MiB run used 700 private chunks and a real ready notification. The Standard User resume run retained 5,690,700 bytes over a disconnect and tab close, then requested the remaining 5,690,699 bytes. The downloaded files matched the reference checksums. The measured Apex callout counts were zero.

A fresh scratch deployment passed all seven focused Apex tests. The REST smoke reconstructed the 5,177,692-byte fixture in ten authenticated requests with a matching SHA-256 and zero Apex callouts. The authentication probe returned HTTP 401 without a Salesforce session.

## Generate a synthetic fixture locally

From this directory, run the following. Python uses only the standard library and writes a deterministic six-page PDF.

```sh
python3 scripts/setup-smoke.py
pdfinfo scratch-output/fixture.pdf
```

The fixture contains legible synthetic pages plus padding in the page streams so the download crosses multiple durable checkpoints. The original PDF is preserved locally for a byte-for-byte comparison.

## Reproduce in a scratch org

Use a scratch org already authorized in the Salesforce CLI. Deploy this project, then run the focused Apex tests.

```sh
sf project deploy start --source-dir force-app --target-org "$PORTWOOD_SCRATCH"
sf apex run test --class-names ApexPdfRangeRestTest,PortwoodPdfReadyNotificationTest \
  --target-org "$PORTWOOD_SCRATCH" --wait 10
```

Assign `PortwoodPdfDownload` to the Salesforce user exercising the page. Set `PORTWOOD_VIEWER` to that user's existing CLI alias in the same scratch org and `PORTWOOD_VIEWER_USERNAME` to their Salesforce username. The staging script creates private `ContentVersion` records owned by that user and prints the new manifest ID and browser URL. The same owner must run the REST probe. For a Standard User owner, grant that user API and `ApexPdfRangeRest` class access explicitly when exercising the REST route.

```sh
sf org assign permset --name PortwoodPdfDownload --target-org "$PORTWOOD_SCRATCH" \
  --on-behalf-of "$PORTWOOD_VIEWER_USERNAME"
mkdir -p scratch-output
python3 scripts/setup-smoke.py --org "$PORTWOOD_VIEWER" | tee scratch-output/fixture.json
PORTWOOD_MANIFEST_ID=$(jq -er '.manifestId' scratch-output/fixture.json)
python3 scripts/verify-range.py "$PORTWOOD_MANIFEST_ID" --org "$PORTWOOD_VIEWER" \
  --reference scratch-output/fixture.pdf --output scratch-output/rest-download.pdf
```

The `--org` flag is the only option that stages the fixture. It writes small Files to the named scratch org. The script uses the CLI session in memory, never prints the access token, and does not create a public distribution. The supplied manifest ID is a per-run identifier and should stay out of committed evidence.

For a browser resume smoke, open the printed URL in Chrome or Edge with the manifest owner's Salesforce session. Click **Download PDF** and, once the page has checkpointed the first segment, interrupt the connection and close the tab. Network throttling makes the checkpoint easier to observe. Restore the connection, reopen the same authenticated URL in a new tab, and click **Download PDF** again. Use the browser console to inspect the following page data during the run.

```js
document.getElementById('downloadPage').dataset
```

Look for positive `checkpointBytes` before interruption and the same `resumedBytes` on the reopened run, with positive `verifiedChunks`. `downloadedBytes` counts the fresh payload accepted on that attempt. The first committed segment is 2,097,152 bytes at the fixture's chunk size. Compare the browser save with the fixture using `shasum -a 256`. Opening a second tab while the first holds the download lock should show that another tab is downloading the same revision.

To exercise a ready notification explicitly, run `PortwoodPdfReadyNotification.enqueue((Id) 'YOUR_MANIFEST_ID');` in Execute Anonymous as the manifest owner. This sends a Lightning notification to that same user. The download landing page also works directly with the URL printed by the setup script.

## Porting considerations

The portable pieces are the authenticated job link, sealed byte-range manifest, exact-length reads, and verified browser checkpoints. The archive object is a dedicated scratch backing store with owner-only reads. A product integration should bind each manifest to the authorized job and its exact File versions, retain Salesforce sharing checks, and verify the browser storage and authentication flow in the managed app.

The page protects verified resume blocks with SHA-256 checkpoints stored in origin-private browser storage. The cache is bound to the Salesforce user and revision. The in-progress download uses six bounded reads. It keeps a temporary completed disk export long enough for the browser download and then removes it. Browser storage limits and enterprise browser policies can affect support.
