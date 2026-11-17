Put several documents into one PDF, or combine PDFs already saved on a record.

**Before you start:** Use a desktop browser. Your administrator must enable the runner's packet or PDF-combining controls.

#### Make a packet from templates

1. Open the Salesforce record and find Portwood Runner.
2. Choose **Document Packet**.
3. Move the required templates into the packet list.
4. Put them in the order you want readers to see them.
5. If needed, choose the option to include existing PDFs from the record and select those files.
6. Generate and download the packet.
7. Open the result and check the document order, page breaks, and completeness.

Use templates that support PDF output. Packet availability depends on the selected templates and the controls enabled on the page.

#### Combine existing PDFs

1. Choose **Combine PDFs** in the runner.
2. Select at least two PDFs already attached to the record.
3. Order them.
4. Combine and download the result.

This does not require a template. It is useful for collecting a finished proposal, terms, and attachments into one file.

#### Add an attachment after a generated document

For a PDF template, use **Combine with existing PDFs on this record** if offered. Choose the PDFs to append, then generate.

Packets and PDF combines are download workflows. If the result also belongs on the record, upload the finished packet to Files.

For a packet that needs signatures, use the [template signing workflow](#sign-template) instead of treating a combined unsigned download as a completed signing request.

#### Automatically include PDFs from a template

Open an existing template and select **PDF Attachments**. Find a Salesforce File
by name, choose its exact PDF version, and add it before or after the generated
document. Use the arrows to set the order on each side, then select **Save PDF
Attachments**.

Standard PDF generation in Runner and the **Generate Document** Flow action
include every configured file. A later upload to the same Salesforce File does
not change the pinned version. The generating user needs access to each file,
and generation stops if a required file is unavailable or cannot be merged.
The native merger's size limits apply to the complete packet. Giant Query PDF
output does not support template attachments. For one-off Flow additions, use
the **Portwood: Merge PDFs** action on the generated file.

The configuration belongs to the template record and applies when switching
between versions of that record. Configure the PDF files again when moving a
template to another org.
