Install Portwood once, then give each person the access they need.

**Before you start:** You need a Salesforce administrator who can install packages and assign permission sets. Try a sandbox before changing a live org.

#### 1. Install the package

Open the link for your environment:

- [Install Portwood {{version}} in production](https://login.salesforce.com/packaging/installPackage.apexp?p0={{packageId}})
- [Install Portwood {{version}} in a sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0={{packageId}})

Sign in to the intended org. Choose **Install for Admins Only**, then complete Salesforce's installation prompts. Wait for installation to finish before continuing.

#### 2. Give yourself Portwood Admin

1. Open Salesforce **Setup**.
2. Enter **Permission Sets** in Quick Find and open it.
3. Open **Portwood Admin**.
4. Choose **Manage Assignments → Add Assignments**.
5. Select your user and complete the assignment.

Give other people **Portwood User** when they need to generate documents or send signing requests. Give **Portwood Admin** to people who build and maintain templates.

Select the people who need the tool. Some Salesforce licenses cannot receive all of these permissions; assigning a set to an unsupported license can also prevent a later upgrade.

#### 3. Check PDF rendering

In Setup, open **Release Updates**. If your org offers **Use the Visualforce PDF Rendering Service for Blob.toPdf() Invocations**, open it and follow Salesforce's steps to enable it.

The update's availability and controls depend on your Salesforce release. A disabled **Enable Test Run** button is not proof that the update is active. If PDF output shows raw CSS or missing images, ask your Salesforce administrator to check the update and contact Salesforce Support if it cannot be enabled.

#### 4. Open Portwood

Open the **App Launcher**, search for **Portwood**, and select the app. You should see the **Template Library** and the choices **Bring an Existing Template** and **Start from a Blank Canvas**.

![Portwood's current template wizard, with the existing-file and blank-canvas choices](docs/images/userguide/v3.60/create-template.png)

**You are ready when:** You can open Portwood and begin creating a template.

#### What needs its own setup?

- A **Generate** component on a record: [Add Portwood to a record page](#add-to-record-page).
- External signing: [Set up external signing](#setup-signatures).
- One-click button management: [Create document and email buttons](#document-buttons).
- AI authoring: [Get help from AI](#ai-authoring).

Installing the package does not automatically add components to your record pages.
