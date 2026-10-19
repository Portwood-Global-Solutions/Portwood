/**
 * Platform Event trigger for signature PDF generation and notifications.
 * Runs as Automated Process user (system context), bypassing guest user
 * limitations on ContentVersion access and email sending.
 * Published by the guest user VF page after each signature action.
 */
trigger DocGenSignaturePdfTrigger on DocGen_Signature_PDF__e(after insert) {
    DocGenSignaturePdfEventHandler.handle(Trigger.New);
}
