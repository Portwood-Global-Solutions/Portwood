import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import LightningConfirm from 'lightning/confirm';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import listRequests from '@salesforce/apex/DocGenSignatureManagementController.listRequests';
import manageRequest from '@salesforce/apex/DocGenSignatureManagementController.manageRequest';
import correctEmail from '@salesforce/apex/DocGenSignatureManagementController.correctEmail';

export default class DocGenSignatureManagement extends NavigationMixin(LightningElement) {
    currentRecordId;
    requests = [];
    error;
    busy = false;
    correction;
    loadSequence = 0;

    @api
    get recordId() {
        return this.currentRecordId;
    }

    set recordId(value) {
        if (value === this.currentRecordId) {
            return;
        }
        this.currentRecordId = value;
        this.requests = [];
        this.error = undefined;
        this.correction = undefined;
        if (value) {
            this.refresh();
        } else {
            ++this.loadSequence;
            this.busy = false;
        }
    }

    get hasRequests() {
        return this.requests.length > 0;
    }

    async refresh() {
        const load = ++this.loadSequence;
        this.busy = true;
        this.error = undefined;
        try {
            const requests = await listRequests({ recordId: this.recordId });
            if (load === this.loadSequence) {
                this.requests = requests;
            }
        } catch (error) {
            if (load === this.loadSequence) {
                this.requests = [];
                this.error = this.errorMessage(error);
            }
        } finally {
            if (load === this.loadSequence) {
                this.busy = false;
            }
        }
    }

    view(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.id, actionName: 'view' }
        });
    }

    async manage(event) {
        const { id: requestId, action } = event.currentTarget.dataset;
        const recordId = this.recordId;
        const verb = action === 'revoke' ? 'Revoke' : 'Resend';
        const confirmed = await LightningConfirm.open({
            label: verb + ' signature request',
            message:
                action === 'revoke'
                    ? 'This invalidates all unsigned signing links.'
                    : 'This sends new links to the active signers and invalidates their previous links.'
        });
        if (!confirmed || recordId !== this.recordId) {
            return;
        }
        await this.run(async () => {
            await manageRequest({ recordId, requestId, action });
            return action === 'revoke'
                ? 'Signature request revoked'
                : 'Resend processed. Check email status for delivery details.';
        });
    }

    openCorrection(event) {
        const { request: requestId, signer: signerId } = event.currentTarget.dataset;
        const signer = this.requests
            .find((request) => request.id === requestId)
            ?.signers.find((row) => row.id === signerId);
        if (signer) {
            this.correction = { requestId, signerId, expectedEmail: signer.email };
        }
    }

    closeCorrection() {
        this.correction = undefined;
    }

    async saveCorrection() {
        const input = this.template.querySelector('[data-corrected-email]');
        if (!input || !input.reportValidity()) {
            return;
        }
        const params = { ...this.correction, recordId: this.recordId, correctedEmail: input.value };
        await this.run(async () => {
            const currentTurn = await correctEmail(params);
            if (params.recordId === this.recordId) {
                this.closeCorrection();
            }
            return currentTurn
                ? 'Email corrected. Check email status for delivery details.'
                : 'Email corrected. The signer will be notified when their turn arrives.';
        });
    }

    async run(action) {
        if (this.busy) {
            return;
        }
        const record = this.recordId;
        const load = ++this.loadSequence;
        this.busy = true;
        try {
            const message = await action();
            if (record === this.recordId) {
                this.dispatchEvent(new ShowToastEvent({ title: message, variant: 'success' }));
                await this.refresh();
            }
        } catch (error) {
            if (record === this.recordId) {
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Signature request action failed',
                        message: this.errorMessage(error),
                        variant: 'error'
                    })
                );
            }
        } finally {
            if (load === this.loadSequence) {
                this.busy = false;
            }
        }
    }

    errorMessage(error) {
        return error?.body?.message || error?.message || 'Please try again.';
    }
}
