import { LightningElement, track, wire } from 'lwc';
import getSettingsFresh from '@salesforce/apex/DocGenSetupController.getSettingsFresh';
import saveSettings from '@salesforce/apex/DocGenSetupController.saveSettings';
import saveSignatureSettings from '@salesforce/apex/DocGenSetupController.saveSignatureSettings';
import getOrgWideEmailAddresses from '@salesforce/apex/DocGenSetupController.getOrgWideEmailAddresses';
import validateSignatureSetup from '@salesforce/apex/DocGenSetupController.validateSignatureSetup';
import saveReminderSettings from '@salesforce/apex/DocGenSetupController.saveReminderSettings';
import saveVerificationSettings from '@salesforce/apex/DocGenSetupController.saveVerificationSettings';
import saveDeclineSettings from '@salesforce/apex/DocGenSetupController.saveDeclineSettings';

export default class DocGenSignatureSettings extends LightningElement {
    @track isLoaded = false;
    @track isSaving = false;
    @track saveMessage = '';
    @track saveSuccess = false;

    @track siteUrl = '';
    @track companyName = '';
    @track brandColor = '#0176D3';
    @track logoUrl = '';
    @track emailSubject = '';
    @track emailMessage = '';
    @track footerText = '';
    @track owaId = '';
    @track owaOptions = [];

    // Reminders + link expiration
    @track reminderEnabled = false;
    @track reminderHours = 24;
    @track reminderSchedule = '24';
    @track expirationDays = 2;

    // #verification — org defaults
    @track requireVerification = true;
    @track prefillEmail = false;

    // #367 — org-wide master switch, off by default (Decline hidden until shown).
    @track showDecline = false;

    // Setup checks
    @track setupChecks = [];
    @track setupChecksLoaded = false;

    connectedCallback() {
        this._loadSettings();
        this._loadSetupChecks();
    }

    async _loadSettings() {
        try {
            const data = await getSettingsFresh();
            this.siteUrl = data.Experience_Site_Url__c || '';
            this.companyName = data.Company_Name__c || '';
            this.brandColor = data.Signature_Email_Brand_Color__c || '#0176D3';
            this.logoUrl = data.Signature_Email_Logo_Url__c || '';
            this.emailSubject = data.Signature_Email_Subject__c || '';
            this.emailMessage = data.Signature_Email_Message__c || '';
            this.footerText = data.Signature_Email_Footer_Text__c || '';
            this.owaId = data.Signature_OWA_Id__c || '';
            this.reminderEnabled = data.Signature_Reminder_Enabled__c === true;
            this.reminderHours = data.Signature_Reminder_Hours__c || 24;
            this.reminderSchedule = data.Signature_Reminder_Schedule__c || String(this.reminderHours);
            this.expirationDays = data.Signature_Expiration_Days__c || 2;
            // null → required (upgrade-safe default)
            this.requireVerification = data.Signature_Require_Email_Verification__c !== false;
            this.prefillEmail = data.Signature_Prefill_Signer_Email__c === true;
            this.showDecline = data.Signature_Show_Decline__c === true;
        } catch (_err) {
            // Settings not yet created — use defaults
        }
        this.isLoaded = true;
    }

    async _loadSetupChecks() {
        this.setupChecksLoaded = false;
        try {
            this.setupChecks = await validateSignatureSetup();
        } catch (_err) {
            this.setupChecks = [];
        }
        this.setupChecksLoaded = true;
    }

    @wire(getOrgWideEmailAddresses)
    wiredOwas({ data }) {
        if (data) {
            this.owaOptions = data;
        }
    }

    handleSiteUrlChange(e) {
        this.siteUrl = e.target.value;
    }
    handleOwaChange(e) {
        this.owaId = e.detail.value;
    }
    handleReminderEnabledChange(e) {
        this.reminderEnabled = e.target.checked;
    }
    handleReminderHoursChange(e) {
        this.reminderHours = e.target.value;
    }
    handleReminderScheduleChange(e) {
        this.reminderSchedule = e.target.value;
    }
    handleExpirationDaysChange(e) {
        this.expirationDays = e.target.value;
    }
    handleRequireVerificationChange(e) {
        this.requireVerification = e.target.checked;
    }
    handlePrefillEmailChange(e) {
        this.prefillEmail = e.target.checked;
    }
    handleShowDeclineChange(e) {
        this.showDecline = e.target.checked;
    }

    handleRefreshChecks() {
        this._loadSetupChecks();
    }

    get allChecksPassed() {
        return this.setupChecks.length > 0 && this.setupChecks.every((c) => c.passed);
    }

    get saveLabel() {
        return this.isSaving ? 'Saving...' : 'Save Settings';
    }

    get saveMessageClass() {
        return (
            'slds-m-top_small slds-p-around_small slds-text-align_center ' +
            (this.saveSuccess ? 'slds-theme_success' : 'slds-theme_error')
        );
    }

    async handleSave() {
        // Surface pattern/min/max violations on the inputs before calling Apex.
        const inputsValid = [...this.template.querySelectorAll('lightning-input')].reduce(
            (valid, input) => input.reportValidity() && valid,
            true
        );
        if (!inputsValid) {
            this.saveSuccess = false;
            this.saveMessage = 'Fix the highlighted fields and try again.';
            return;
        }
        this.isSaving = true;
        this.saveMessage = '';
        try {
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            await saveSettings({ experienceSiteUrl: this.siteUrl });
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            await saveSignatureSettings({
                brandColor: this.brandColor,
                logoUrl: this.logoUrl,
                emailSubject: this.emailSubject,
                emailMessage: this.emailMessage,
                footerText: this.footerText,
                companyName: this.companyName,
                owaId: this.owaId
            });
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            const schedule = (this.reminderSchedule || '').trim();
            const firstOffset = parseInt(schedule.split(',')[0], 10);
            await saveReminderSettings({
                enabled: this.reminderEnabled,
                hours: firstOffset > 0 ? firstOffset : parseInt(this.reminderHours, 10) || 24,
                schedule,
                expirationDays: parseInt(this.expirationDays, 10) || null
            });
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            await saveVerificationSettings({
                requireVerification: this.requireVerification,
                prefillEmail: this.prefillEmail
            });
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            await saveDeclineSettings({ showDecline: this.showDecline });
            this.saveSuccess = true;
            this.saveMessage =
                'Settings saved successfully.' + (this.reminderEnabled ? ' Reminders scheduled hourly.' : '');
            // Re-validate setup after save
            this._loadSetupChecks();
        } catch (err) {
            this.saveSuccess = false;
            this.saveMessage = this.errMsg(err);
        } finally {
            this.isSaving = false;
        }
    }

    // Normalizes the LWC error shapes (AuraHandledException, DML page/field errors,
    // array bodies) into a display string — err.body.message can be a non-string,
    // which otherwise renders as "[object Object]".
    errMsg(err) {
        const body = err && err.body;
        if (Array.isArray(body) && body[0] && typeof body[0].message === 'string') {
            return body[0].message;
        }
        if (body) {
            if (typeof body.message === 'string' && body.message) {
                return body.message;
            }
            if (body.pageErrors && body.pageErrors[0] && body.pageErrors[0].message) {
                return String(body.pageErrors[0].message);
            }
            if (body.fieldErrors) {
                const fieldKey = Object.keys(body.fieldErrors)[0];
                const fieldErr = fieldKey && body.fieldErrors[fieldKey][0];
                if (fieldErr && fieldErr.message) {
                    return String(fieldErr.message);
                }
            }
        }
        if (err && typeof err.message === 'string' && err.message) {
            return err.message;
        }
        return 'Failed to save settings.';
    }
}
