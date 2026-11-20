@IsTest
private class DocGenEmailInlineImagesTest {
    private static EmailMessage email(Id caseId, String subject, String html) {
        return new EmailMessage(
            ParentId = caseId,
            Subject = subject,
            HtmlBody = html,
            Status = '1',
            Incoming = true,
            FromAddress = 'sender@example.invalid',
            ToAddress = 'support@example.invalid'
        );
    }

    private static Id imageFile(Id emailId, String baseName) {
        ContentVersion file = new ContentVersion(
            Title = baseName,
            PathOnClient = baseName + '.png',
            VersionData = Blob.valueOf('image fixture'),
            FirstPublishLocationId = emailId
        );
        insert file;
        return file.Id;
    }

    @IsTest
    static void resolvesOnlyUniqueFilesLinkedToTheSameEmail() {
        Case ticket = new Case(Subject = 'Inline image proof');
        insert ticket;
        EmailMessage first = email(ticket.Id, 'First email', '<p>first <img src="cid:logo.png"/></p>');
        EmailMessage second = email(ticket.Id, 'Second email', '<p>second <img src="cid:logo.png"/></p>');
        EmailMessage unrelated = email(ticket.Id, 'Third email', '<p>third</p>');
        insert new List<EmailMessage>{ first, second, unrelated };
        Id firstImage = imageFile(first.Id, 'logo');
        Id secondImage = imageFile(second.Id, 'logo');
        Id thirdImage = imageFile(unrelated.Id, 'logo');

        first.HtmlBody +=
            '<img src="cid:' +
            thirdImage +
            '" alt="other email"/>' +
            '<img src="cid:' +
            firstImage +
            '" alt="same email"/>';
        second.HtmlBody += '<img src="cid:opaque@end.invalid" alt="opaque ID"/>';
        Test.startTest();
        DocGenEmailInlineImages.prepare(new List<SObject>{ first, second });
        Test.stopTest();

        String prefix = '/sfc/servlet.shepherd/version/download/';
        Assert.isTrue(first.HtmlBody.contains(prefix + firstImage + '"/>'));
        Assert.isTrue(first.HtmlBody.contains(prefix + firstImage + '" alt="same email"/>'));
        Assert.isFalse(first.HtmlBody.contains(String.valueOf(thirdImage)));
        Assert.isTrue(first.HtmlBody.contains('[Image: other email]'));
        Assert.isTrue(second.HtmlBody.contains(prefix + secondImage + '"/>'));
        Assert.isFalse(second.HtmlBody.contains(String.valueOf(firstImage)));
        Assert.isTrue(second.HtmlBody.contains('[Image: opaque ID]'));
        Assert.isFalse(second.HtmlBody.contains('cid:'));
    }

    @IsTest
    static void doesNotGuessBetweenDuplicateFilenames() {
        Case ticket = new Case(Subject = 'Ambiguous inline image');
        insert ticket;
        EmailMessage message = email(ticket.Id, 'test', '<img src="cid:logo.png" alt="logo"/>');
        insert message;
        Id first = imageFile(message.Id, 'logo');
        imageFile(message.Id, 'logo');
        message.HtmlBody += '<img src="cid:' + first + '"/>';

        DocGenEmailInlineImages.prepare(new List<SObject>{ message });

        Assert.isTrue(message.HtmlBody.startsWith('<span>[Image: logo]</span>'));
        Assert.isTrue(message.HtmlBody.endsWith('/' + first + '"/>'));
    }

    @IsTest
    static void keepsLocalSourceAndSafelyOmitsUnsupportedOrMalformedImages() {
        String html =
            '<p>start<IMG SRC=/resource/logo alt="A > B" width="40" srcset="https://example.invalid/alternate" ' +
            'style="background:url(https://example.invalid/style)">' +
            '<img src = "https://example.invalid/tracker" alt="&lt;remote&gt;"/>' +
            '<img src="data:image/png;base64,AAAA" alt="embedded"/>' +
            '<img src="/resource/duplicate" src="https://example.invalid/second" alt="duplicate"/>' +
            '<img src="https://example.invalid/broken> ending</p>';

        String result = DocGenEmailInlineImages.rewrite(html, null);

        Assert.isTrue(result.contains('<img src="/resource/logo" alt="A &gt; B" width="40"/>'), result);
        Assert.isTrue(result.contains('<span>[Image: &lt;remote&gt;]</span>'));
        Assert.isTrue(result.contains('<span>[Image: embedded]</span>'));
        Assert.isTrue(result.contains('<span>[Image: duplicate]</span>'));
        Assert.isTrue(result.endsWith(' ending</p>'));
        Assert.isFalse(result.contains('example.invalid'));
        Assert.isFalse(result.contains('srcset'));
        Assert.isFalse(result.contains('data:'));
    }

    @IsTest
    static void preservesAltAroundOversizedDataImagesWithoutPassingTheSourceThrough() {
        String inlineData = 'data:image/png;base64,' + 'A'.repeat(9000);
        String html =
            '<p>before<img src="' +
            inlineData +
            '" alt="long &amp; large > visible"/>' +
            ' between <img alt="alt first" src=' +
            inlineData +
            ' />' +
            ' then <img src="' +
            inlineData +
            '> after</p>';

        Assert.areEqual(
            '<p>before<span>[Image: long &amp; large &gt; visible]</span>' +
            ' between <span>[Image: alt first]</span> then  after</p>',
            DocGenEmailInlineImages.rewrite(html, null)
        );
    }
}
