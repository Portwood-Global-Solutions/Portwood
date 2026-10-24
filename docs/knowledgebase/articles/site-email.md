The public page and the email sender are separate parts of signing setup. A working page does not prove that invitations or verification codes can be delivered.

**Before you start:** Use an administrator account and a real sender/inbox controlled by your organization. Domain authentication can require your email or DNS administrator.

#### 1. Create the sender address

1. In **Setup**, search for **Organization-Wide Addresses**.
2. Add the intended display name and email address.
3. Make it available to the profiles required by the signing workflow, including the guest completion path where applicable.
4. Open Salesforce's verification message in that inbox and complete verification.
5. Confirm the address is verified and eligible before selecting it in Portwood.

A brand can have its own sender, but that address also needs to be verified and usable. An address that an admin can select is not proof that every runtime path can use it.

#### 2. Complete Salesforce email prerequisites

Check **Setup → Deliverability** and the org's sending-domain verification/authentication requirements. Use your organization's approved sender domain, DKIM and other domain records as required by Salesforce and your email setup. Sandbox/scratch delivery restrictions and unverified domains can prevent mail even when the Portwood settings look complete.

Use Salesforce's current [Organization-Wide Addresses documentation](https://help.salesforce.com/s/articleView?id=sf.emailadmin_manage_orgwide_email_addresses.htm&language=en_US&type=5) and [requirements for sending email](https://help.salesforce.com/s/articleView?id=xcloud.security_email_verification_requirements.htm&language=en_US&type=5) for the platform controls.

#### 3. Select it in Portwood

1. Open **Portwood → Signatures**.
2. Choose the verified address in **Send Emails From**.
3. Save and click **Re-check Setup**.
4. Set the default email verification, pre-fill, expiration, and reminder choices.
5. Open [Brands and Email Templates](#brands-and-emails) if you want different identities or wording.

Check the actual template and send review: template/request overrides can change whether a code is required. Suppressing branded invitations does not suppress required PIN verification emails.

#### 4. Test each delivery separately

| Test               | Check                                                                                            |
| ------------------ | ------------------------------------------------------------------------------------------------ |
| Invitation         | Right sender, subject, brand, recipient, and working link                                        |
| Verification code  | Code arrives in the expected inbox and unlocks the request                                       |
| Sequential signing | Only the currently eligible signer gets the appropriate invitation                               |
| Reminder           | Schedule and sender match your intended operation; reminders currently use the org-wide identity |
| Completion         | Expected recipients receive completion and can access the intended result                        |

Use an inbox you control and a practice document. Open the signing link outside your Salesforce session. Check spam/quarantine and the request's **Email Status** when delivery fails; an already-sent status cannot guarantee that an external mail system placed the message in an inbox.

#### Keep a repeatable setup check

When changing domains, site URLs, guest users, brands, senders, or verification policy, run the public test again. Record which part failed: link, PDF preview, code delivery, signing, file save, or completion delivery. That makes support much faster than a general “signing does not work.”

The fresh knowledgebase org deliberately used no production sender. Site/public signing and email rendering can be tested separately, but actual invitation/PIN/reminder/completion delivery still requires a verified sender and a controlled inbox.
