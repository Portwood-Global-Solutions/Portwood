import { LightningElement, track, wire } from 'lwc';
import getOrgId from '@salesforce/apex/DocGenController.getOrgId';
import canManageButtons from '@salesforce/apex/DocGenButtonAdminController.canManageButtons';
import DOCGEN_LOGO from '@salesforce/resourceUrl/DocGenLogo';

export default class DocGenCommandHub extends LightningElement {
    logoUrl = DOCGEN_LOGO;
    communityOrgId = '';
    @track activeSection = 'templates';
    // The Buttons tab is shown only to users who have the DocGen_Button_Manager
    // permission set (needed to call canManageButtons at all) AND the platform
    // metadata-write permission the builder's Metadata API deploy requires. A
    // user without class access gets a rejected promise → tab stays hidden.
    @track showButtonsTab = false;
    buttonAccessPending = true;

    connectedCallback() {
        canManageButtons()
            .then((allowed) => {
                this.showButtonsTab = allowed === true;
            })
            .catch(() => {
                this.showButtonsTab = false;
            })
            .finally(() => {
                this.buttonAccessPending = false;
            });
    }

    @wire(getOrgId)
    wiredOrgId({ data }) {
        if (data) {
            this.communityOrgId = data;
        }
    }

    get communityUrl() {
        return 'https://portwood.dev/community?view=signup&orgId=' + this.communityOrgId;
    }

    get isTemplates() {
        return this.activeSection === 'templates';
    }
    get isBulk() {
        return this.activeSection === 'bulk';
    }
    get isSignatures() {
        return this.activeSection === 'signatures';
    }
    get isAssets() {
        return this.activeSection === 'assets';
    }
    get isButtons() {
        return this.activeSection === 'buttons';
    }
    get isSendEmail() {
        return this.activeSection === 'sendEmail';
    }
    get showButtonsSection() {
        return this.activeSection === 'buttons' && this.showButtonsTab;
    }
    get showSendEmailSection() {
        return this.activeSection === 'sendEmail' && this.showButtonsTab;
    }
    get isEmail() {
        return this.activeSection === 'email';
    }
    get isBrands() {
        return this.activeSection === 'brands';
    }
    get isHelp() {
        return this.activeSection === 'help';
    }
    get templatesTabClass() {
        return this.activeSection === 'templates' ? 'tab-active' : '';
    }
    get bulkTabClass() {
        return this.activeSection === 'bulk' ? 'tab-active' : '';
    }
    get signaturesTabClass() {
        return this.activeSection === 'signatures' ? 'tab-active' : '';
    }
    get assetsTabClass() {
        return this.activeSection === 'assets' ? 'tab-active' : '';
    }
    get buttonsTabClass() {
        return this.activeSection === 'buttons' ? 'tab-active' : '';
    }
    get sendEmailTabClass() {
        return this.activeSection === 'sendEmail' ? 'tab-active' : '';
    }
    get emailTabClass() {
        return this.activeSection === 'email' ? 'tab-active' : '';
    }
    get brandsTabClass() {
        return this.activeSection === 'brands' ? 'tab-active' : '';
    }
    get helpTabClass() {
        return this.activeSection === 'help' ? 'tab-active' : '';
    }

    handleShowTemplates() {
        this.activeSection = 'templates';
    }
    handleShowBulk() {
        this.activeSection = 'bulk';
    }
    handleShowSignatures() {
        this.activeSection = 'signatures';
    }
    handleShowAssets() {
        this.activeSection = 'assets';
    }
    handleShowButtons() {
        this.activeSection = 'buttons';
    }
    handleShowSendEmail() {
        this.activeSection = 'sendEmail';
    }
    handleShowEmail() {
        this.activeSection = 'email';
    }
    handleShowBrands() {
        this.activeSection = 'brands';
    }
    handleShowHelp() {
        this.activeSection = 'help';
    }

    handleCopyTag(event) {
        let tag = event.currentTarget.dataset.tag;
        if (tag === 'loop-contacts') tag = '{#Contacts}...{/Contacts}';
        if (navigator.clipboard) {
            navigator.clipboard.writeText(tag);
        }
    }
}
