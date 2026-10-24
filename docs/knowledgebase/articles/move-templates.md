Move a working template from a sandbox to production, or share it with another Portwood org.

#### Export from the first org

1. Open **My Templates → Your Templates**.
2. Find the template and choose **Show actions → Export**.
3. Keep the downloaded `.docgen.json` file.

The bundle includes the active version and its document, template settings, supported inline images, watermark, and saved queries. Older version history stays in the original org.

#### Import into the other org

1. Make sure a compatible Portwood version is installed.
2. Open **My Templates → Your Templates → Import Template**.
3. Select the `.docgen.json` bundle.
4. Open the imported template and review its settings.
5. Choose a sample record from the destination org.
6. Generate and review a real document before offering it to users.

#### Check what differs between orgs

- Custom objects, fields, and related lists must exist in the destination.
- A record ID from the old org does not identify the same record in the new one.
- Review audience permission-set names, record filters, and specific-record restrictions.
- Recheck sending brands, approved custom fonts, external signing setup, and any separately managed shared assets or provider classes. Do not assume every dependency is in a template bundle.
- The **API Name** is preserved unless the destination already has a template using that key. In that case, resolve the conflict before connecting automation.

#### Give automation a stable name

Set the template's **API Name** to a unique value such as `Account_Brief`. Use it in supported Flow actions and Portwood buttons so you do not have to replace a template record ID after moving between orgs.

**You are done when:** The imported template generates correctly in the destination and its users and automations can find the intended template.
