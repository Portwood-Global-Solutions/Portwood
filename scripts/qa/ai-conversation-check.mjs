import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
let reply;
const events = [];
class Element {
    dispatchEvent(event) {
        events.push(event.detail);
    }
}
const source = fs
    .readFileSync('force-app/main/default/lwc/docGenAiConversation/docGenAiConversation.js', 'utf8')
    .replace(/^import .*;$/gm, '')
    .replace(/@api\b/g, '')
    .replace('export default class DocGenAiConversation', 'class Conversation');
const Conversation = vm.runInNewContext(source + '\nConversation;', {
    LightningElement: Element,
    CustomEvent: class {
        constructor(type, options) {
            this.detail = options.detail;
        }
    },
    converse: (args) => reply(args)
});
const plan = {
    objectName: 'Account',
    objectLabel: 'Account',
    queryConfig: JSON.stringify({
        v: 3,
        root: 'Account',
        nodes: [{ id: 'root', object: 'Account', fields: ['Name'] }]
    }),
    sections: []
};
const chat = new Conversation();
chat.available = true;
let round = 0;
reply = async (args) => {
    if (round++ === 0) return { kind: 'schema', historyJson: args.historyJson, message: 'Finding fields' };
    return { kind: 'ask', historyJson: args.historyJson, message: 'Open cases only, or closed cases too?' };
};
chat.draft = 'An account briefing with support cases.';
await chat.handleSend();
assert.equal(round, 2);
assert.equal(chat.turns.length, 2);
assert.equal(chat.turns[1].role, 'Agentforce');
assert.equal(chat.plan, null);
assert.equal(chat.draft, '');
assert.equal(events.at(-1).status, 'ask');
reply = async (args) => ({ ...plan, kind: 'ready', historyJson: args.historyJson, message: 'Only open cases.' });
chat.draft = 'Only open cases, no date window or row limit.';
await chat.handleSend();
assert.equal(events.at(-1).status, 'ready');
assert.equal(events.at(-1).objectName, 'Account');
assert.match(events.at(-1).brief, /Only open cases/);
chat.handleInput({ target: { value: 'Include recently closed cases too.' } });
assert.equal(events.at(-1).status, 'composing', 'Unsent changes block stale generation.');
assert.equal(chat.hasUnsentChanges, true);
chat.handleInput({ target: { value: '' } });
assert.equal(events.at(-1).status, 'ready');
chat.referenceKey = 'new-example-revision';
assert.equal(chat.plan, null);
assert.equal(events.at(-1).status, 'changed');
assert.ok(
    chat.history.every((m) => m.role === 'user'),
    'Reference changes keep customer intent, not old model evidence.'
);
let release;
reply = () =>
    new Promise((resolve) => {
        release = resolve;
    });
chat.draft = 'A different document';
const pending = chat.handleSend();
chat.handleStartOver();
release({ ...plan, kind: 'ready', historyJson: '[]', message: 'Old response' });
await pending;
assert.equal(chat.plan, null);
assert.equal(chat.turns.length, 0, 'A late reply cannot resurrect a reset conversation.');
assert.equal(chat.busy, false);
chat.draft = 'Keep the next section together';
let textarea = { value: 'old request' };
chat.template = { querySelector: () => textarea };
chat.renderedCallback();
assert.equal(textarea.value, chat.draft, 'Native textarea reflects cleared/replaced draft state.');
const admin = fs.readFileSync('force-app/main/default/lwc/docGenAdmin/docGenAdmin.js', 'utf8');
const start = admin.indexOf("if (this.isAuthoringAi && this.dataSourceMode === 'record')");
const end = admin.indexOf("if (this.isAuthoringAi && this.dataSourceMode === 'flow')", start);
assert.ok(start > 0 && end > start);
assert.ok(
    !admin.slice(start, end).includes('_buildDefaultQueryConfig'),
    'AI never preselects a query before understanding the request.'
);
assert.match(admin.slice(start, end), /newTemplateObject = ''/);
const kit = fs.readFileSync('force-app/main/default/lwc/docGenAuthoringKit/docGenAuthoringKit.js', 'utf8');
for (const rule of [
    'ADVANCED PRINT FORMATTING',
    'white-space:nowrap',
    'page-break-inside:avoid',
    'page-break-after:avoid',
    'orphans:2',
    'row taller',
    'tfoot',
    'rowspan'
])
    assert.ok(kit.includes(rule), rule);
console.log(
    'PASS: conversational schema hops, business follow-ups, validated plan handoff, stale/unsent protection, reference changes, cancellation, no guessed AI query, and advanced print guidance.'
);
