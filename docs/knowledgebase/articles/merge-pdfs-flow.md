Combine an approval letter and a schedule already stored in Salesforce Files. This Flow action creates a new File and returns its IDs, so a later step can attach it to a record or offer it to the user.

1. In a sandbox, open the bundled **Portwood: PDF Merge Demo** in Flow Builder. It ships as a draft. Debug it with two small unsigned PDFs you can read.
2. Supply **Content Version IDs** as an ordered Text collection, or **Content Version IDs (Text)** as a single value separated by spaces, commas, semicolons or line breaks. Choose one input. Use exact version IDs beginning with `068`. A document ID beginning with `069` identifies the file across revisions and cannot select the source revision.
3. Set **Document Title**. Set **Related Record ID** to link the new File there. Leave it blank for a standalone File.
4. Turn on **Pad Odd Documents** for duplex printing. Every odd-length source gets a trailing blank, including the last source. Repeating an ID repeats that PDF.
5. Branch on **Success**. Keep **Content Version ID** for that output revision and **Content Document ID** to open or link the File. Display **Error Message** on failure and connect a fault path.

One one-page letter followed by one two-page schedule produces three pages normally, or four with padding. Flip through the result and verify the first page of the schedule comes after the blank.

The action accepts 2–100 source versions and checks their combined input size before reading them. The budget is at most 384 KiB synchronously and 768 KiB asynchronously. Available Apex heap can lower it. Each repeated input counts again. Encrypted or signed PDFs, XFA, and scripted/calculation forms are rejected. For a signed agreement, assemble its final contents before requesting signatures.

For an interactive desktop download, see [Document packets](#document-packets).

The [sandbox-generated duplex packet](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/acceptance/duplex-packet.pdf) uses two one-page sources. The welcome letter is on page 1, the flattened acceptance form is on page 3, and pages 2 and 4 are blank.

For a familiar first run, use the downloaded sample letter and acceptance form from the [recipe library](#recipe-library). Upload the two PDFs to Files and use their version IDs in the sample Flow.
