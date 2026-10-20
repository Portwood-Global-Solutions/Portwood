// Creates the two sample Files used by DocGen_Merge_PDFs_Demo. Safe to rerun:
// only missing sample Files are created, and existing documents are retained.
Set<String> titles = new Set<String>{ 'Portwood Merge Demo - Welcome', 'Portwood Merge Demo - Project Brief' };
Set<String> existing = new Set<String>();
for (ContentVersion cv : [SELECT Title FROM ContentVersion WHERE Title IN :titles AND IsLatest = TRUE WITH USER_MODE]) {
    existing.add(cv.Title);
}
String css =
    '<style>@page{size:letter;margin:0.65in}body{font-family:Arial,sans-serif;font-size:11pt;color:#243347}' +
    'h1{font-size:30pt;line-height:1.15;color:#123e60;margin:30pt 0 18pt}h2{font-size:17pt;color:#123e60;margin-top:26pt}' +
    'p{line-height:1.55}.brand{font-size:16pt;font-weight:bold;color:#123e60}.eyebrow{font-size:9pt;color:#527085;letter-spacing:1pt}' +
    '.bar{background:#d49a35;height:4pt;margin:18pt 0 28pt}.callout{background:#edf4f7;padding:18pt;margin:24pt 0}' +
    'table{border-collapse:collapse;width:100%;margin-top:16pt}th{text-align:left;background:#edf4f7;padding:10pt}' +
    'td{padding:10pt;border-bottom:1pt solid #dce4ea}.source{font-size:9pt;color:#527085;margin-top:36pt}' +
    '.page{page-break-before:always}</style>';
Map<String, String> bodies = new Map<String, String>();
bodies.put(
    'Portwood Merge Demo - Welcome',
    '<div class="brand">PORTWOOD</div><div class="bar"></div>' +
        '<div class="eyebrow">WELCOME LETTER</div><h1>One clear packet.<br/>Everything in order.</h1>' +
        '<p>Prepared for <strong>Northstar Studio</strong></p><p>Welcome aboard. Your project brief and delivery checklist follow this letter in one convenient PDF.</p>' +
        '<div class="callout"><strong>Your packet, assembled</strong><p>1. Welcome letter &mdash; 1 page<br/>2. Project brief &amp; delivery checklist &mdash; 2 pages</p></div>' +
        '<h2>What happens next</h2><p>Review the project scope, confirm the delivery milestones, and keep this packet with your project records.</p>' +
        '<p class="source">SOURCE A &nbsp; | &nbsp; Welcome letter &nbsp; | &nbsp; Page 1 of 1</p>'
);
bodies.put(
    'Portwood Merge Demo - Project Brief',
    '<div class="brand">PORTWOOD</div><div class="bar"></div>' +
        '<div class="eyebrow">PROJECT BRIEF</div><h1>A smooth start<br/>for Northstar Studio.</h1>' +
        '<p>A shared plan for the people, documents, and decisions that move this project forward.</p>' +
        '<table><tr><th>Milestone</th><th>Outcome</th></tr><tr><td>Discover</td><td>Confirm goals and requirements</td></tr>' +
        '<tr><td>Build</td><td>Prepare the working solution</td></tr><tr><td>Deliver</td><td>Review and hand over the final packet</td></tr></table>' +
        '<h2>Success looks like</h2><p>Everyone has the same information, the next steps are clear, and the completed documents are easy to find.</p>' +
        '<p class="source">SOURCE B &nbsp; | &nbsp; Project brief &nbsp; | &nbsp; Page 1 of 2</p>' +
        '<div class="page"></div><div class="brand">PORTWOOD</div><div class="bar"></div>' +
        '<div class="eyebrow">DELIVERY CHECKLIST</div><h1>Ready for<br/>the next chapter.</h1>' +
        '<table><tr><th>Item</th><th>Ready when</th></tr><tr><td>Project scope</td><td>The team has agreed on the deliverables</td></tr>' +
        '<tr><td>Review</td><td>Feedback is resolved and approved</td></tr><tr><td>Document packet</td><td>The welcome letter, brief, and checklist are together</td></tr>' +
        '<tr><td>Handover</td><td>The final PDF is saved with the project</td></tr></table>' +
        '<div class="callout"><strong>One file. Three pages.</strong><p>The merged packet keeps the welcome letter first, followed by both pages of this project brief.</p></div>' +
        '<p class="source">SOURCE B &nbsp; | &nbsp; Delivery checklist &nbsp; | &nbsp; Page 2 of 2</p>'
);
List<ContentVersion> files = new List<ContentVersion>();
for (String title : titles) {
    if (existing.contains(title))
        continue;
    Blob pdf = Blob.toPdf('<html><head>' + css + '</head><body>' + bodies.get(title) + '</body></html>');
    files.add(new ContentVersion(Title = title, PathOnClient = title + '.pdf', VersionData = pdf));
}
if (!files.isEmpty())
    Database.insert(files, AccessLevel.USER_MODE);
for (ContentVersion cv : [
    SELECT Id, Title, ContentSize
    FROM ContentVersion
    WHERE Title IN :titles AND IsLatest = TRUE
    WITH USER_MODE
]) {
    System.debug('DEMO_SOURCE ' + cv.Title + ' | ' + cv.Id + ' | ' + cv.ContentSize + ' bytes');
}
