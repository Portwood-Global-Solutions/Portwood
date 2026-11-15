import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export const MAX_RECEIPTS = 100_000;

const year = 2025;
const bytes = value => Buffer.from(value, 'ascii');
const header = Buffer.from('%PDF-1.4\n%\xe2\xe3\xcf\xd3\n', 'latin1');
const ink = '0.09 0.17 0.20';
const accent = '0.01 0.37 0.32';
const muted = '0.29 0.37 0.39';
const paper = '0.96 0.97 0.95';
const fundNames = ['Community program', 'Education fund', 'Food assistance', 'General support'];

function validOrdinal(ordinal) {
  assert.ok(Number.isSafeInteger(ordinal) && ordinal >= 1 && ordinal <= MAX_RECEIPTS,
    `Receipt ordinal must be an integer from 1 to ${MAX_RECEIPTS}.`);
}

function serial(ordinal) {
  return String(ordinal).padStart(6, '0');
}

export function receiptId(ordinal) {
  validOrdinal(ordinal);
  return `PW-RCPT-${year}-${serial(ordinal)}`;
}

function pdfString(value) {
  return `(${value.replace(/[()\\]/g, character => '\\' + character)})`;
}

function drawText(font, size, x, y, value, color = ink) {
  return `q ${color} rg BT /${font} ${size} Tf 1 0 0 1 ${x} ${y} Tm ${pdfString(value)} Tj ET Q`;
}

function rectangle(x, y, width, height, color) {
  return `q ${color} rg ${x} ${y} ${width} ${height} re f Q`;
}

function streamBody(dictionary, contents) {
  return `<< ${dictionary}/Length ${Buffer.byteLength(contents, 'ascii')} >>\nstream\n${contents}\nendstream`;
}

function object(id, body) {
  return bytes(`${id} 0 obj\n${body}\nendobj\n`);
}

// The same embedded vector mark and standard font resources occur in each independent fixture.
const logo = [
  'q 0.01 0.37 0.32 rg 0 0 38 38 re f',
  '1 1 1 RG 2.5 w 10 10 m 10 28 l 22 28 l 26 24 l 22 19 l 10 19 l S',
  '24 10 m 29 10 l 29 15 l S Q',
].join('\n');
const prefixObjects = [
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R ' +
    '/Resources << /Font << /R 4 0 R /B 5 0 R >> /XObject << /Mark 6 0 R >> >> >>',
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>',
  streamBody('/Type /XObject /Subtype /Form /FormType 1 /BBox [0 0 38 38] /Resources << >> ', logo),
].map((body, index) => object(index + 1, body));

let prefixBytes = header.length;
const references = ['xref\n0 8\n0000000000 65535 f \n'];
for (const part of prefixObjects) {
  references.push(String(prefixBytes).padStart(10, '0') + ' 00000 n \n');
  prefixBytes += part.length;
}
references.push(String(prefixBytes).padStart(10, '0') + ' 00000 n \n');
const prefix = Buffer.concat([header, ...prefixObjects]);
const xref = references.join('') + 'trailer\n<< /Size 8 /Root 1 0 R >>\nstartxref\n';

function amount(cents) {
  const totalDollars = Math.floor(cents / 100);
  return '$' + totalDollars + '.' + String(cents % 100).padStart(2, '0');
}

export function receiptPdf(ordinal) {
  const id = receiptId(ordinal);
  const number = serial(ordinal);
  const giftCount = 1 + ordinal % 4;
  const rows = [];
  let total = 0;
  for (let index = 0; index < giftCount; index++) {
    const month = 2 + index * 3;
    const day = 1 + (ordinal * 7 + index * 3) % 27;
    const date = `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
    const cents = 500 + (ordinal * 617 + index * 3767) % 849500;
    const position = 456 - index * 30;
    total += cents;
    rows.push(
      drawText('R', 11, 62, position, date),
      drawText('R', 11, 190, position, fundNames[(ordinal + index) % fundNames.length]),
      drawText('B', 11, 448, position, amount(cents)),
      rectangle(62, position - 10, 488, 0.6, '0.82 0.86 0.84'),
    );
  }
  const contents = [
    rectangle(0, 0, 612, 792, paper),
    rectangle(0, 623, 612, 169, ink),
    'q 1 0 0 1 46 720 cm /Mark Do Q',
    drawText('B', 13, 99, 744, 'PORTWOOD COMMUNITY FOUNDATION', '1 1 1'),
    drawText('R', 9, 99, 726, 'SYNTHETIC BENCHMARK ORGANIZATION', '0.67 0.84 0.81'),
    drawText('B', 27, 46, 675, 'Year-end donation receipt', '1 1 1'),
    drawText('R', 13, 46, 648, `January 1 to December 31, ${year}`, '0.78 0.91 0.86'),
    rectangle(42, 164, 528, 438, '1 1 1'),
    drawText('B', 10, 62, 566, 'DONOR', accent),
    drawText('B', 15, 62, 544, `Donor ${number} - Test Household`),
    drawText('B', 10, 365, 566, 'RECEIPT ID', accent),
    drawText('R', 12, 365, 544, id),
    drawText('R', 11, 62, 516, 'Thank you for supporting our community programs.'),
    rectangle(62, 473, 488, 25, '0.91 0.94 0.92'),
    drawText('B', 9, 70, 481, 'GIFT DATE'),
    drawText('B', 9, 190, 481, 'FUND'),
    drawText('B', 9, 448, 481, 'AMOUNT'),
    ...rows,
    rectangle(62, 299, 488, 29, '0.91 0.94 0.92'),
    drawText('B', 11, 71, 309, 'Total gifts received (USD)'),
    drawText('B', 12, 448, 309, amount(total)),
    drawText('R', 11, 62, 266, 'This receipt summarizes the listed contributions for the calendar year.'),
    drawText('R', 11, 62, 247, 'The sample records no goods or services provided in return for these gifts.'),
    drawText('B', 10, 62, 199, 'SYNTHETIC TEST DOCUMENT', accent),
    drawText('R', 10, 46, 125, 'Donation receipt fixture for PDF generation and merge benchmarks.', muted),
  ].join('\n');
  const body = object(7, streamBody('', contents));
  const suffix = bytes(xref + (prefix.length + body.length) + '\n%%EOF\n');
  return Buffer.concat([prefix, body, suffix]);
}

export async function verifyReceiptPdf(filename, expectedCount) {
  validOrdinal(expectedCount);
  const path = resolve(filename);
  const info = execFileSync('pdfinfo', [path], { encoding: 'utf8' });
  const pageCount = Number(/^Pages:\s+(\d+)$/m.exec(info)?.[1]);
  assert.equal(pageCount, expectedCount, 'PDF page count');

  const child = spawn('pdftotext', ['-enc', 'UTF-8', path, '-'], { stdio: ['ignore', 'pipe', 'inherit'] });
  const closed = once(child, 'close');
  child.stdout.setEncoding('utf8');
  let pending = '';
  let ordinal = 0;
  try {
    for await (const data of child.stdout) {
      const parts = (pending + data).split('\f');
      pending = parts.pop();
      for (const page of parts) {
        ordinal++;
        const ids = page.match(/\bPW-RCPT-\d{4}-\d{6}\b/g) ?? [];
        assert.deepEqual(ids, [receiptId(ordinal)], `Receipt identifier on page ${ordinal}`);
      }
    }
    const [code, signal] = await closed;
    assert.equal(code, 0, `pdftotext failed${signal ? ` with signal ${signal}` : ''}`);
    assert.equal(pending.trim(), '', 'Expected a form-feed at each page boundary.');
    assert.equal(ordinal, expectedCount, 'Receipts by page');
  } catch (error) {
    child.kill();
    await closed.catch(() => {});
    throw error;
  }
  return { pages: pageCount, receiptIdsVerified: ordinal, ordered: true };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [command, filename, count] = process.argv.slice(2);
  if (command !== 'verify' || !filename || !count) {
    throw new Error('Usage: node scripts/bench/portwood-receipt-fixtures.mjs verify FILE COUNT');
  }
  console.log(JSON.stringify(await verifyReceiptPdf(filename, Number(count))));
}
