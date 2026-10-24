Upload a logo once and reuse it across templates.

#### Add a shared image

1. Open **Portwood → Assets**.
2. Add an image, give it a clear name, and choose a stable asset key such as `company-logo`.
3. Upload the image file and save it.
4. Use the asset's copy or insert controls when placing it in a template.

An asset key is a reusable name. `{%asset:company-logo}` points to that image without tying your template to an org-specific file ID.

#### Put it in a document

- **Canvas:** Choose **Image**, place a block, and choose the asset. Resize it on the page.
- **HTML designer:** Use the Images/Assets panel to insert it.
- **Word or hand-authored HTML:** Use an image tag, for example `{%asset:company-logo:160x}`. Leaving one dimension blank preserves the image's proportions.

Keep logos small enough for their intended print size. A very large photograph can increase file size without improving a small printed logo.

#### Use a picture stored on a record

Portwood also supports image fields and attached record images through image merge tags. Use the template's copy-paste tag tools to get the correct form for your data. Include the image field in the query when the tag reads a field.

Use the [image tag reference](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/merge-tags.md#77-images) for numbered attached images, field images, and exact sizing.

#### Replace a shared logo

Update the asset's image, then generate a document using it. Because templates refer to the key, you do not need to replace the tag in every template. Check headers, footers, and emails too if they use that asset.

Email images need publicly accessible links. Document images and email images have different access requirements; see [Brand the signing experience](#brands-and-emails) before putting a private Salesforce file URL in an email.

**You are done when:** The image appears in a real generated PDF at the intended size. An image visible only in the browser preview is not enough.
