import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getButtons from '@salesforce/apex/DocGenButtonController.getButtons';
import generate from '@salesforce/apex/DocGenButtonController.generate';

const DELIVERY_PREVIEW = 'PREVIEW';

/**
 * docGenPreviewButton
 * -------------------
 * Headless record action: generates the document and opens it in Salesforce's file preview,
 * with no dialog. It uses the record's first active Portwood Button whose Delivery Mode is
 * Preview. The regular Portwood Button action (c:docGenButton) always shows a dialog, and
 * closing that dialog cancels the preview it opened, so a "preview only" button that leaves
 * nothing behind has to be a headless action.
 */
export default class DocGenPreviewButton extends NavigationMixin(LightningElement) {
    @api recordId;
    _busy = false;

    @api
    async invoke() {
        if (this._busy) {
            return;
        }
        this._busy = true;
        try {
            const options = await getButtons({ recordId: this.recordId });
            const previewButtons = (options || []).filter((o) => o.deliveryMode === DELIVERY_PREVIEW);
            if (previewButtons.length === 0) {
                this.toast(
                    'No preview button',
                    'No active Portwood Button on this record has Delivery Mode set to Preview. ' +
                        'Set one in Command Hub → Buttons, or use the regular Portwood Button action.',
                    'warning'
                );
                return;
            }
            const res = await generate({
                recordId: this.recordId,
                configDeveloperName: previewButtons[0].developerName
            });
            if (!res || !res.success || !res.contentDocumentId) {
                this.toast(
                    'Could not generate document',
                    (res && res.errorMessage) || 'No file was returned.',
                    'error'
                );
                return;
            }
            this[NavigationMixin.Navigate]({
                type: 'standard__namedPage',
                attributes: { pageName: 'filePreview' },
                state: { selectedRecordId: res.contentDocumentId }
            });
        } catch (e) {
            this.toast(
                'Could not generate document',
                (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error.',
                'error'
            );
        } finally {
            this._busy = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
