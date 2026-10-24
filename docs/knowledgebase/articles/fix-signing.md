Check the request and delivery state before resending.

#### The invitation or code email did not arrive

1. Check the recipient's address and spam folder.
2. Check **Email Status** on the signature request.
3. Confirm this is not an internal **Preview signing in Salesforce** request; that delivery intentionally suppresses invitations, reminders, and completion emails.
4. Ask the administrator to check Salesforce Deliverability, the verified Organization-Wide Email Address, profile availability, sending-domain authentication, and email limits.

On a sequential request, later signers may not be invited until the preceding signer completes.

Changing DNS or email security policy requires your email administrator. Use the actual delivery error to decide what to change.

#### The public link says Invalid page

Ask the administrator to check **Signature Site URL**. An Experience Cloud base URL should not end with `/s`. Confirm the signing Visualforce pages are enabled on the site currently serving the links, and that its own guest user has **Portwood Guest Signature**.

After correcting setup, test a fresh request. Moving to another site does not transfer the old site's guest assignments automatically.

#### The page opens but the PDF says Document unavailable

For Experience Cloud, check **Administration → Preferences → Let guest users view asset files, library files, and CMS content available to the site**. Then confirm guest permissions and test again outside a signed-in Salesforce session.

Classic Salesforce Sites do not use that particular Experience Cloud preference.

#### The link expired or was already used

Open the request's status. A resend replaces unsigned signers' old links; a revoke invalidates them; a completed signer cannot sign again. Send the person the newest valid link through the intended workflow rather than copying an old invitation.

#### Continue or Review request is disabled

For uploaded PDFs, check:

- Every recipient has a name and valid email.
- Every recipient has at least one Signature field.
- Fields stay within page boundaries.
- The PDF is unlocked, unsigned, no larger than 2 MB, and no more than 50 pages.
- The request is within the 10-recipient and 100-field limits.

For template requests, also check signer roles against the template's signature tags.

#### The signed file is missing

Check whether **all** required signers finished, refresh requests, and open Files on the related record. Look at the request's completion state and Portwood Error Logs before sending a duplicate request.
