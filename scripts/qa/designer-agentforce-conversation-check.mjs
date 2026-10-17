import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

// Exercise the actual designer handlers with a controlled Apex boundary.
const source = fs.readFileSync('force-app/main/default/lwc/docGenAdmin/docGenAdmin.js', 'utf8');
function method(name) {
    const start = source.indexOf('    ' + name);
    assert.ok(start >= 0, name);
    return source.slice(start, source.indexOf('\n    }', start) + 6);
}
const methods = [
    'get _currentDesignerBody()',
    'get canEditWithAgentforce()',
    'get isAgentforceEditMode()',
    'get agentforceNeedsDiscardConfirm()',
    'get agentforceSendDisabled()',
    'handleAgentforceDraftChange(event)',
    'handleAgentforceKeydown(event)',
    '_addAgentforceTurn(role, content)',
    '_resetAgentforceConversation()',
    'handleNewAgentforceConversation()',
    'handleOpenAgentforcePanel()',
    'handleCloseAgentforcePanel()',
    'async handleGenerateWithAgentforce()'
]
    .map(method)
    .join('\n');
let respond;
const requests = [];
const timers = [];
const Conversation = vm.runInNewContext('class Conversation {' + methods + '}; Conversation;', {
    converseTemplate: async (args) => {
        requests.push(args);
        return respond(args);
    },
    buildAiPrompt: (_, options) => JSON.stringify(options),
    extractQueryShape: () => ({}),
    ShowToastEvent: class {},
    requestAnimationFrame: (fn) => fn(),
    setTimeout: (fn) => timers.push(fn)
});
function designer() {
    const chat = new Conversation();
    Object.assign(chat, {
        editTemplateId: 'template-a',
        _agentforceRequest: 0,
        _agentforceTurnId: 0,
        agentforceTurns: [],
        agentforceDraft: '',
        aiDocDescription: 'An unrelated creation wizard brief',
        body: '<html><body><h1>{Name}</h1><p>Original wording.</p></body></html>',
        template: { querySelector: () => null },
        _currentDraftHtml() {
            return this.body;
        },
        _buildFieldTypeMap() {
            return {};
        },
        _syncHtmlBodyEditorDom(html) {
            this.body = html;
            this.applied++;
        },
        _enterVisualMode(html) {
            this.body = html;
        },
        _exitVisualMode() {},
        dispatchEvent() {},
        applied: 0
    });
    chat.handleOpenAgentforcePanel();
    return chat;
}
const chat = designer();
assert.equal(chat.agentforceMode, 'edit');
assert.equal(chat.agentforceDraft, '', 'A wizard description must never become a refinement message.');
assert.equal(chat.agentforceSendDisabled, true);
respond = async () => ({ message: 'Which heading color would you like?' });
chat.agentforceDraft = 'Change the heading color.';
await chat.handleGenerateWithAgentforce();
assert.equal(chat.agentforceTurns.length, 2);
assert.equal(chat.agentforceTurns[1].content, 'Which heading color would you like?');
assert.equal(chat.applied, 0, 'Clarification must not touch the canvas.');
assert.equal(chat.isAgentforcePanelOpen, true);
assert.equal(chat.agentforceDraft, '');

// The author may inspect the canvas, make a manual edit, and then answer the question.
chat.handleCloseAgentforcePanel();
chat.body = '<html><body><h1>{Name}</h1><p>Manual edit.</p></body></html>';
chat.agentforceDraft = 'Dark green.';
chat.handleOpenAgentforcePanel();
assert.equal(chat.agentforceDraft, 'Dark green.');
assert.equal(chat.agentforceTurns.length, 2);
const edited = '<html><body><h1 style="color:#006400">{Name}</h1><p>Manual edit.</p></body></html>';
respond = async () => ({
    message: 'Changed the heading to dark green.',
    generation: { html: edited, wasEdit: true, summary: 'Edit applied.', warningCount: 0, findings: [] }
});
await chat.handleGenerateWithAgentforce();
const request = requests.at(-1);
assert.deepEqual(
    JSON.parse(request.historyJson).map((m) => m.content),
    ['Change the heading color.', 'Which heading color would you like?', 'Dark green.']
);
assert.match(request.previousBody, /Manual edit/);
assert.equal(JSON.parse(request.prompt).docDescription, 'Dark green.');
assert.equal(JSON.parse(request.prompt).currentBody, request.previousBody);
assert.equal(chat.body, edited);
assert.equal(chat.applied, 1);
assert.equal(chat.isAgentforcePanelOpen, true, 'A clean edit keeps the conversation open.');
assert.equal(chat.agentforceMode, 'edit');
assert.equal(chat.aiDocDescription, 'An unrelated creation wizard brief');

respond = async () => {
    throw new Error('Temporary model failure.');
};
chat.agentforceDraft = 'Make the title larger too.';
await chat.handleGenerateWithAgentforce();
assert.match(chat.agentforceError, /Temporary model failure/);
assert.equal(chat.applied, 1);
assert.equal(chat.agentforceTurns.length, 5, 'Failures retain the conversation.');
assert.equal(chat.isAgentforceGenerating, false);

// A second send while waiting must not start another generation.
let release;
respond = () =>
    new Promise((resolve) => {
        release = resolve;
    });
chat.agentforceDraft = 'Try again.';
const pending = chat.handleGenerateWithAgentforce();
const count = requests.length;
await chat.handleGenerateWithAgentforce();
chat.handleCloseAgentforcePanel();
assert.equal(chat.isAgentforcePanelOpen, true, 'Keep the generating canvas protected until the reply arrives.');
assert.equal(requests.length, count);
chat._resetAgentforceConversation();
chat.editTemplateId = 'template-b';
chat.handleOpenAgentforcePanel();
release({ message: 'Old reply', generation: { html: 'WRONG TEMPLATE' } });
await pending;
assert.equal(chat.applied, 1, 'A late reply cannot change a different template.');
assert.equal(chat.agentforceTurns.length, 0);
assert.equal(chat.agentforceError, '');

// A generated document becomes the source for the next turn automatically.
const fresh = designer();
fresh.body = '';
fresh.handleNewAgentforceConversation();
assert.equal(fresh.agentforceMode, 'create');
respond = async () => ({ message: 'Created your document.', generation: { html: edited, findings: [] } });
fresh.agentforceDraft = 'Create an account letter.';
await fresh.handleGenerateWithAgentforce();
assert.equal(requests.at(-1).previousBody, null);
assert.equal(fresh.agentforceMode, 'edit');
respond = async () => ({ message: 'The title uses your approved heading style.' });
fresh.agentforceDraft = 'Which heading style did you use?';
await fresh.handleGenerateWithAgentforce();
assert.equal(requests.at(-1).previousBody, edited);
assert.equal(fresh.applied, 1, 'Discussing a finished document must not regenerate it.');
fresh.handleNewAgentforceConversation();
assert.equal(fresh.body, edited, 'A new conversation clears messages, never the document.');
assert.equal(fresh.agentforceTurns.length, 0);
assert.equal(fresh.isAgentforcePanelOpen, true);
fresh.handleCloseAgentforcePanel();
fresh.handleOpenAgentforcePanel();
assert.equal(fresh.agentforceTurns.length, 0);

const live = designer();
const composer = { value: 'Use the message I just typed.' };
live.template.querySelector = (selector) => (selector === '.dg-af-desc' ? composer : null);
live.agentforceDraft = 'An older draft';
respond = async () => ({ message: 'Understood.' });
await live.handleGenerateWithAgentforce();
assert.equal(JSON.parse(requests.at(-1).historyJson)[0].content, 'Use the message I just typed.');
assert.equal(composer.value, '', 'Sending clears the live composer, including a send before blur.');

// Deferred visual writes also belong to the template/request that scheduled them.
fresh.showHtmlBodyVisual = true;
respond = async () => ({ message: 'Edited.', generation: { html: edited, findings: [] } });
fresh.agentforceDraft = 'Keep the green title.';
await fresh.handleGenerateWithAgentforce();
fresh._resetAgentforceConversation();
fresh.body = 'A different canvas';
for (const timer of timers) timer();
assert.equal(fresh.body, 'A different canvas');

console.log(
    'PASS: designer clarification, follow-up context, latest manual edits, retained threads, errors, duplicate sends, template isolation, create-to-edit handoff, and deferred canvas protection.'
);
