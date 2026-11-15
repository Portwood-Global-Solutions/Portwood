#!/usr/bin/env python3
"""Verify a merged synthetic 2025 Portwood Account packet PDF with one text pass."""

import argparse
from collections import Counter
from datetime import date
from decimal import Decimal
import json
from pathlib import Path
import re
import subprocess


COHORT_10K = 'PW-BENCH-PACKETS-2025'
COHORT_100K = 'PW-BENCH-100K-2025'
COHORTS = {COHORT_10K: (5, 10_000), COHORT_100K: (6, 100_000)}
YEAR = 2025
MONEY = r'\$\s*\d[\d,]*\.\d{2}'
MONEY_PATTERN = re.compile(MONEY)
ALLOCATION = re.compile(rf'^\s*(\S.*?\S)\s+(\d+(?:\.0+)?)\s+({MONEY})\s+({MONEY})\s*$')

# Synthetic fixture inputs from scripts/bench/seed-portwood-account-packets.mjs.
FIRST_NAMES = ('Avery', 'Blair', 'Casey', 'Cameron', 'Drew', 'Emerson', 'Harper', 'Jamie', 'Jules',
               'Kendall', 'Lane', 'Morgan', 'Parker', 'Quinn', 'Riley', 'Rowan', 'Sage', 'Taylor')
LAST_NAMES = ('Bramblewick', 'Cobbleroy', 'Dunegrove', 'Eastfern', 'Foxglade', 'Glasshollow', 'Hawthornley',
              'Ivybriar', 'Kestrelmore', 'Lionbrook', 'Mossbourne', 'Nightingrove', 'Oatmere', 'Pebblehurst',
              'Quillwood', 'Rushden', 'Slatefield', 'Trellisford')
MIDDLE_NAMES = ('Arden', 'Bailey', 'Briar', 'Brook', 'Clarke', 'Cove', 'Dale', 'Dawson', 'Ellis', 'Finch',
                'Frankie', 'Gale', 'Glenn', 'Gray', 'Hollis', 'Indigo', 'Jude', 'Kit', 'Lake', 'Lee', 'Lux',
                'Marlowe', 'North', 'Oak', 'Perry', 'Rain', 'Reese', 'Ren', 'River', 'Sky', 'Vale')
FAMILY_BRANCHES = ('Aldercrest', 'Bluehaven', 'Cinderglen', 'Dawnmere', 'Elmshade', 'Fernlane', 'Goldmarsh',
                   'Hillsworth', 'Ivystone', 'Juniperfall')
ADDRESSES = (('Hawthollow Lane', 'Starling Haven', 'ME', '04991'),
             ('Wrenfield Drive', 'New Aldercrest', 'VT', '05991'),
             ('Tumbleash Road', 'Pine Lantern', 'NH', '03991'),
             ('Amberdell Place', 'Birchgrove Falls', 'MA', '01991'))
PROGRAMS = ('Community Food Program', 'Youth Literacy Fund', 'Winter Assistance Fund', 'Family Resource Center')
PRODUCTS = (('Community Pantry Bundle', 25), ('Youth Literacy Kit', 18), ('Winter Relief Pack', 45),
            ('After-School Supply Set', 30), ('Community Meal Voucher', 12), ('Family Resource Kit', 55),
            ('Learning Lab Materials', 65), ('Neighborhood Care Package', 35))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def collapse(text):
    return ' '.join(text.split())


def money(value):
    return Decimal(value.replace('$', '').replace(',', '').strip())


def expected_gift(ordinal, index, digits=5):
    month = (ordinal * 7 + index * 4) % 12 + 1
    day = (ordinal * 13 + index * 5) % 27 + 1
    gift_date = date(YEAR, month, day)
    allocations = []
    for item in range(2):
        name, unit = PRODUCTS[(ordinal * 3 + index * 2 + item) % len(PRODUCTS)]
        quantity = 1 + (ordinal * 7 + index * 3 + item) % 4
        allocations.append((name, quantity, unit, unit * quantity))
    return {
        'reference': f'PW-PACKET-{ordinal:0{digits}d}-G{index + 1}',
        'date': f'{gift_date:%B} {gift_date.day}, {gift_date.year}',
        'program': PROGRAMS[(ordinal + index) % len(PROGRAMS)],
        'total': sum(allocation[3] for allocation in allocations),
        'allocations': Counter(allocations),
    }


def expected_donor(ordinal, cohort):
    first = FIRST_NAMES[(ordinal - 1) % len(FIRST_NAMES)]
    family_index = (ordinal - 1) // len(FIRST_NAMES)
    last = LAST_NAMES[family_index % len(LAST_NAMES)]
    middle_index = family_index // len(LAST_NAMES)
    middle = MIDDLE_NAMES[middle_index % len(MIDDLE_NAMES)]
    if cohort == COHORT_100K:
        last += '-' + FAMILY_BRANCHES[middle_index // len(MIDDLE_NAMES)]
    name = f'{first} {middle} {last} Household'
    street, city, state, postal = ADDRESSES[ordinal % len(ADDRESSES)]
    street_address = f'{200 + ordinal} {street}'
    locality = f'{city}, {state} {postal}'
    return name, street_address, locality


def verify_page(text, ordinal, cohort, digits, account_pattern, gift_pattern):
    label = f'{ordinal:0{digits}d}'
    prefix = f'Account ordinal {label}'
    lines = [line for line in text.splitlines() if line.strip()]
    require(account_pattern.findall(text) == [label], f'{prefix}: missing, duplicated, or out of order.')
    collapsed = collapse(text)
    name, street_address, locality = expected_donor(ordinal, cohort)
    for field in (name, street_address, locality, 'Annual contribution statement', 'Sample — not issued', 'Gifts received 2'):
        require(field in collapsed, f'{prefix}: missing or incorrect field {field!r}.')

    expected = [expected_gift(ordinal, index, digits) for index in range(2)]
    require(gift_pattern.findall(text) == [(label, '1'), (label, '2')],
            f'{prefix}: expected exactly two gifts in reference order.')
    matches = [next(index for index, line in enumerate(lines) if gift['reference'] in line) for gift in expected]

    heading = '\n'.join(lines[:matches[0] - 1])
    annual_amounts = [money(value) for value in MONEY_PATTERN.findall(heading)]
    require(annual_amounts == [sum(gift['total'] for gift in expected)], f'{prefix}: annual total differs from the backend fixture.')
    require('total contributed' in heading.casefold(), f'{prefix}: missing annual total heading.')

    expected_line_count = 0
    for index, gift in enumerate(expected):
        start = matches[index]
        stop = matches[index + 1] - 1 if index + 1 < len(matches) else len(lines)
        require(gift['date'] in collapse(lines[start]), f"{gift['reference']}: incorrect gift date.")
        gift_heading = collapse(lines[start - 1])
        require(gift_heading.startswith(gift['program'] + ' '), f"{gift['reference']}: incorrect gift designation.")
        require([money(value) for value in MONEY_PATTERN.findall(gift_heading)] == [gift['total']],
                f"{gift['reference']}: incorrect gift amount.")
        allocations = Counter()
        for line in lines[start + 1:stop]:
            match = ALLOCATION.fullmatch(line)
            if match:
                product, quantity, unit_price, allocation = match.groups()
                allocations[(collapse(product), int(Decimal(quantity)), money(unit_price), money(allocation))] += 1
        require(allocations == gift['allocations'], f"{gift['reference']}: expected exactly two corresponding line items.")
        expected_line_count += sum(allocations.values())

    actual_line_count = sum(ALLOCATION.fullmatch(line) is not None for line in lines)
    require(actual_line_count == expected_line_count == 4, f'{prefix}: duplicate, unmatched, or missing allocations.')


def pages(path):
    with subprocess.Popen(['pdftotext', '-layout', '-enc', 'UTF-8', str(path), '-'],
                          stdout=subprocess.PIPE, text=True, encoding='utf-8') as process:
        sections = []
        try:
            for line in process.stdout:
                parts = line.split('\f')
                sections.append(parts[0])
                for part in parts[1:]:
                    yield ''.join(sections)
                    sections = [part]
            require(not ''.join(sections).strip(), 'Text extraction ended without the final page delimiter.')
            require(process.wait() == 0, 'PDF text extraction failed.')
        finally:
            if process.poll() is None:
                process.kill()


def verify(pdf, first, count, cohort):
    digits, _ = COHORTS[cohort]
    account_pattern = re.compile(rf'\b{re.escape(cohort)}-(\d{{{digits}}})\b')
    gift_pattern = re.compile(rf'\bPW-PACKET-(\d{{{digits}}})-G([12])\b')
    page_count = 0
    for page in pages(pdf):
        page_count += 1
        require(page_count <= count, f'The output has more than {count} pages.')
        verify_page(page, first + page_count - 1, cohort, digits, account_pattern, gift_pattern)
    require(page_count == count, f'Expected {count} pages and saw {page_count}.')
    return page_count


def manifest_coverage(manifests):
    indexes = []
    all_ids = set()
    gift_ids = set()
    line_ids = set()
    cohort = None
    for path in manifests:
        manifest = json.loads(path.read_text())
        current = manifest.get('cohort')
        require(current in COHORTS and manifest.get('year') == YEAR, f'Unexpected fixture cohort in {path.name}.')
        require(cohort in (None, current), 'Fixture manifests cannot mix cohorts.')
        cohort = current
        digits, maximum = COHORTS[cohort]
        count = manifest['accountCount']
        first = manifest.get('firstOrdinal', 1)
        last = manifest.get('lastOrdinal', first + count - 1)
        require(manifest.get('ordinalWidth', digits) == digits and 1 <= first <= last <= maximum and
                last - first + 1 == count, f'Inconsistent ordinal coverage in {path.name}.')
        require(count * 2 == manifest.get('opportunityCount') and
                count * 4 == manifest.get('opportunityLineItemCount'), f'Inconsistent backend counts in {path.name}.')
        ids = manifest.get('accountIds', [])
        expected_ids = set(ids)
        require(len(ids) == count and len(expected_ids) == count and not all_ids.intersection(expected_ids) and
                all(re.fullmatch(r'001[A-Za-z0-9]{15}', account_id) for account_id in ids),
                f'Expected one unique backend Account ID per statement in {path.name}.')
        all_ids.update(expected_ids)
        if manifest.get('schemaVersion') == 2:
            records = manifest.get('records', [])
            require(len(records) == count, f'Missing ordered record tree in {path.name}.')
            for ordinal, account_id, record in zip(range(first, last + 1), ids, records):
                require(record.get('ordinal') == ordinal and record.get('accountId') == account_id,
                        f'Backend manifest Account position {ordinal} is incorrect.')
                gifts = record.get('opportunities', [])
                require(len(gifts) == 2, f'Backend Account {ordinal} requires two Opportunity IDs.')
                for gift in gifts:
                    gift_id = gift.get('opportunityId', '')
                    require(re.fullmatch(r'006[A-Za-z0-9]{15}', gift_id) and gift_id not in gift_ids,
                            f'Backend Account {ordinal} has an invalid or repeated Opportunity ID.')
                    gift_ids.add(gift_id)
                    items = gift.get('lineItemIds', [])
                    require(len(items) == 2, f'Backend Account {ordinal} requires two IDs per OpportunityLineItem list.')
                    for item_id in items:
                        require(re.fullmatch(r'00k[A-Za-z0-9]{15}', item_id) and item_id not in line_ids,
                                f'Backend Account {ordinal} has an invalid or repeated OpportunityLineItem ID.')
                        line_ids.add(item_id)
        indexes.append((first, last))
    indexes.sort()
    for previous, following in zip(indexes, indexes[1:]):
        require(previous[1] + 1 == following[0], 'Backend manifests must cover one contiguous range without overlaps.')
    return cohort, indexes[0][0], indexes[-1][1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pdf', type=Path)
    parser.add_argument('--manifest', type=Path, action='append')
    parser.add_argument('--cohort', choices=COHORTS)
    parser.add_argument('--count', type=int)
    parser.add_argument('--first-ordinal', type=int)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()

    try:
        cohort = args.cohort
        first = args.first_ordinal
        count = args.count
        if args.manifest:
            backend, available_first, available_last = manifest_coverage(args.manifest)
            require(cohort in (None, backend), 'Requested cohort disagrees with the backend fixture manifests.')
            cohort = backend
            first = available_first if first is None else first
            count = available_last - first + 1 if count is None else count
            require(available_first <= first and first + count - 1 <= available_last,
                    'Requested range exceeds the backend fixture manifests.')
        cohort = COHORT_10K if cohort is None else cohort
        first = 1 if first is None else first
        digits, maximum = COHORTS[cohort]
        count = maximum - first + 1 if count is None else count
        require(1 <= first <= maximum and 1 <= count <= maximum and first + count - 1 <= maximum,
                f'Expected a bounded range of up to {maximum:,} account statements.')
        require(args.pdf.is_file(), 'Merged PDF does not exist.')
        page_count = verify(args.pdf, first, count, cohort)
        report = {
            'cohort': cohort,
            'ordinalWidth': digits,
            'pages': page_count,
            'verifiedAccounts': page_count,
            'verifiedOpportunities': page_count * 2,
            'verifiedOpportunityLineItems': page_count * 4,
            'firstOrdinal': first,
            'lastOrdinal': first + page_count - 1,
            'backendManifestMatched': args.manifest is not None,
            'verification': 'Every account, address, gift reference, date, fund, amount, and associated allocation checked against the synthetic fixture.',
        }
    except (KeyError, TypeError, ValueError, OSError) as error:
        parser.exit(1, f'{error}\n')

    evidence = json.dumps(report, indent=2) + '\n'
    if args.report:
        args.report.write_text(evidence)
    print(evidence, end='')


if __name__ == '__main__':
    main()
