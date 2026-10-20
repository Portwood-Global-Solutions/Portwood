import assert from 'node:assert/strict';
import fs from 'node:fs';

const source = fs.readFileSync(
    new URL('../../force-app/main/default/lwc/docGenPageLayout/docGenPageLayout.js', import.meta.url),
    'utf8'
);
const { parsePageLayout, applyPageLayout, pageGeometry, pageMargins } = await import(
    'data:text/javascript;base64,' + Buffer.from(source).toString('base64')
);
let checks = 0;
const check = (name, fn) => {
    fn();
    checks++;
    console.log('PASS ' + name);
};

check('page cascade uses the last simple rule and retains named page rules', () => {
    const html =
        '<style>@page { size: Letter; margin: 1in; } @page wide { size: A4 landscape; } @page { size: Legal; margin: .5in; }</style><p>Keep original wording</p>';
    const page = parsePageLayout(html);
    assert.equal(page.size, 'Legal');
    const edited = applyPageLayout(html, { ...page, size: 'A4' });
    assert.ok(edited.includes('@page { size: Letter; margin: 1in; }'));
    assert.ok(edited.includes('@page wide { size: A4 landscape; }'));
    assert.ok(edited.endsWith('<p>Keep original wording</p>'));
    assert.equal(parsePageLayout(edited).size, 'A4');
});
check('nested counters and quoted braces survive changing page setup', () => {
    const html =
        '<style>@page { size: Letter; margin: 1in; @bottom-center { content: "{Page} " counter(page) " / " counter(pages); color: red; } }</style>';
    const edited = applyPageLayout(html, { ...parsePageLayout(html), size: 'A4', orient: 'landscape' });
    assert.ok(edited.includes('@bottom-center { content: "{Page} " counter(page) " / " counter(pages); color: red; }'));
    assert.deepEqual(
        [pageGeometry(parsePageLayout(edited)).width, pageGeometry(parsePageLayout(edited)).height],
        [297 / 25.4, 210 / 25.4]
    );
});
check('one, two, three and four margin values expand correctly', () => {
    for (const [css, expected] of [
        ['1in', [1, 1, 1, 1]],
        ['1in 2in', [1, 2, 1, 2]],
        ['1in 2in 3in', [1, 2, 3, 2]],
        ['1in 2in 3in 4in', [1, 2, 3, 4]]
    ]) {
        assert.deepEqual(pageMargins(parsePageLayout('@page { margin: ' + css + '; }')), expected);
    }
});
check('CSS absolute units and unitless zero are recognized', () => {
    const margins = pageMargins(parsePageLayout('@page { margin: 25.4mm 2.54cm 72pt 0; }'));
    margins.forEach((value, index) => assert.ok(Math.abs(value - [1, 1, 1, 0][index]) < 1e-10));
});
check('zero and asymmetric margins round trip without a fallback', () => {
    const page = { ...parsePageLayout(''), marginTop: '0', marginRight: '.25', marginBottom: '.75', marginLeft: '1' };
    const html = applyPageLayout('<html><body>Text</body></html>', page);
    assert.deepEqual(pageMargins(parsePageLayout(html)), [0, 0.25, 0.75, 1]);
    assert.ok(html.includes('<html><body>Text</body></html>'));
});
check('custom landscape geometry round trips through PDF CSS', () => {
    const page = { ...parsePageLayout(''), size: 'Custom', customW: '10', customH: '15', orient: 'landscape' };
    const read = parsePageLayout(applyPageLayout('', page));
    assert.deepEqual([pageGeometry(read).width, pageGeometry(read).height], [15, 10]);
    assert.equal(read.orient, 'landscape');
});
check('new values replace conflicting margin longhands and preserve unrelated CSS', () => {
    const html = '<style>@page { margin: 1in; margin-left: 2in; background-color: white; } h1 { color: blue; }</style>';
    const edited = applyPageLayout(html, { ...parsePageLayout(html), marginLeft: '0' });
    assert.deepEqual(pageMargins(parsePageLayout(edited)), [1, 1, 1, 0]);
    assert.ok(edited.includes('background-color: white;'));
    assert.ok(edited.includes('h1 { color: blue; }'));
});
check('invalid printable area is rejected', () => {
    assert.throws(() => applyPageLayout('', { ...parsePageLayout(''), marginLeft: '8', marginRight: '1' }), /Margins/);
});
check('margin shorthand and longhands obey declaration order', () => {
    assert.deepEqual(pageMargins(parsePageLayout('@page { margin-left:2in; margin:1in; }')), [1, 1, 1, 1]);
    assert.deepEqual(pageMargins(parsePageLayout('@page { margin:1in; margin-left:2in; }')), [1, 1, 1, 2]);
});
console.log(`${checks} page-layout scenarios passed.`);
