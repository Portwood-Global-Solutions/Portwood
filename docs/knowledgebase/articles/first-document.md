Make a small Account summary. Start with a title and two fields; you can add tables and pictures after the first PDF works.

**Before you start:** You have **Portwood Admin**, Portwood is installed, and you have an Account with a name and phone number. The examples use **Northstar Bikes**; any test Account is fine.

#### 1. Make the template

1. Open **App Launcher → Portwood**.
2. Under **My Templates → Create New**, choose **Start from a Blank Canvas**.
3. Enter **My First Account Brief** in **Template Name**.
4. Set **Base Object** to **Account**. If suggestions appear, choose the standard Account.
5. Click **Create & Open Canvas**.

If the template list appears, use the template's **Show actions → Design** menu to open its Canvas.

#### 2. Choose a record to preview

1. Click **Data** on the left of the Canvas.
2. In **Preview with this record**, search for your Account and select it.
3. Check that **Account Name** and **Account Phone** are included in the field list.
4. Click **Done**.

This record is your practice example. Choosing it does not limit the template to that Account.

#### 3. Add the words

1. Click **Text** on the left, then click inside the white page. A text box appears.
2. In the box's content editor, enter:

    ```text
    Account brief
    Customer: {Name}
    Phone: {Phone}
    ```

3. Drag the box to where you want it. Make it wide and tall enough to show all three lines.
4. Click **Save**.

Keep the braces around `{Name}` and `{Phone}`. Those are the places Portwood fills in for you.

![A saved Canvas text box shows the Account name and phone from the selected sample record](docs/images/userguide/v3.60/canvas-first-document.png)

#### 4. See the result

1. Click **Preview** in the Canvas toolbar.
2. Open the generated PDF.
3. Check that your Account's name and phone number appear in place of the two tags.

**You are done when:** The PDF says **Customer: Northstar Bikes** (or your Account's name) and shows the phone number from that Account.

![The actual first PDF shows Northstar Bikes and its phone number in place of the tags](docs/images/userguide/v3.60/first-document-result.png)

#### If your result is different

- **The field is blank:** Open the Account and check that it has a value. Then check that the field is included under **Data**.
- **Preview asks for a record:** Return to **Data** and select a record from the search results.
- **Text is cut off:** Select the box and make it taller or wider.
- **Your edit disappeared:** Click **Save** before leaving the Canvas.

Next, [generate from a record page](#generate-document) or [add a repeating list](#repeating-tables).
