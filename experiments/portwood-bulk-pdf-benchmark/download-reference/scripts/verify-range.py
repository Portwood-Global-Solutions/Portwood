#!/usr/bin/env python3
"""Download a private Apex PDF through one URL, using bounded HTTP ranges."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import hashlib
from http.client import HTTPSConnection
import json
from pathlib import Path
import re
import shutil
import subprocess
from tempfile import NamedTemporaryFile
from time import perf_counter
from urllib.parse import urlsplit

from org_auth import org_auth


MAX_RANGE_BYTES = 512 * 1024
CONTENT_RANGE = re.compile(r"bytes (\d+)-(\d+)/(\d+)")


def check(condition, message):
    if not condition:
        raise ValueError(message)


def fetch(connection, path, token=None, requested=None):
    headers = {"Accept-Encoding": "identity"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if requested:
        headers["Range"] = requested
    started = perf_counter()
    connection.request("GET", path, headers=headers)
    response = connection.getresponse()
    body = response.read(MAX_RANGE_BYTES + 1)
    check(len(body) <= MAX_RANGE_BYTES, f"Endpoint returned an unbounded response for {requested}")
    return response, body, (perf_counter() - started) * 1000


def validate_partial(response, body):
    check(response.status == 206, f"Expected HTTP 206, received {response.status}")
    match = CONTENT_RANGE.fullmatch(response.getheader("Content-Range", ""))
    check(match, "Missing or invalid Content-Range")
    start, end, total = map(int, match.groups())
    check(0 <= start <= end < total and len(body) == end - start + 1, "Range length mismatch")
    check(response.getheader("Content-Type", "").split(";")[0] == "application/pdf", "Unexpected content type")
    check(response.getheader("Accept-Ranges") == "bytes", "Endpoint did not advertise byte ranges")
    check("no-store" in response.getheader("Cache-Control", ""), "PDF response can be cached")
    etag = response.getheader("ETag")
    check(etag and not etag.startswith("W/"), "Expected a strong ETag for an immutable revision")
    check(response.getheader("X-Portwood-Callouts") == "0", "Missing or nonzero Apex callout count")
    try:
        heap = int(response.getheader("X-Portwood-Heap-Bytes", ""))
    except ValueError:
        raise ValueError("Missing Apex heap telemetry") from None
    check(heap > 0, "Invalid Apex heap value")
    return start, end, total, etag, heap


def probe(target, token):
    with closing(HTTPSConnection(target.netloc, timeout=60)) as connection:
        response, body, _ = fetch(connection, target.path, token, "bytes=0-4")
        start, end, total, etag, _ = validate_partial(response, body)
        check((start, end, body) == (0, 4, b"%PDF-"), "First range did not return a PDF header")
        statuses = {"firstBytes": response.status}

        bad_requests = {
            "noRange": None,
            "backwardsRange": "bytes=4-0",
            "multipartRange": "bytes=0-1,4-5",
            "pastEnd": f"bytes={total}-{total + 1}",
        }
        if total > MAX_RANGE_BYTES:
            bad_requests["oversizedRange"] = f"bytes=0-{MAX_RANGE_BYTES}"
        for label, requested in bad_requests.items():
            response, _, _ = fetch(connection, target.path, token, requested)
            # Apex REST's status whitelist excludes HTTP 416.
            check(response.status == 400, f"{label}: expected 400, received {response.status}")
            if requested:
                check(response.getheader("Content-Range") == f"bytes */{total}", f"{label}: wrong total")
            statuses[label] = response.status

        suffix_size = min(total, 32)
        suffix_start = total - suffix_size
        response, suffix, _ = fetch(connection, target.path, token, f"bytes=-{suffix_size}")
        check(validate_partial(response, suffix)[:4] == (suffix_start, total - 1, total, etag), "Wrong suffix range")
        check(suffix.rstrip().endswith(b"%%EOF"), "PDF end marker not found in suffix range")
        statuses["suffixRange"] = response.status

        response, clamped, _ = fetch(connection, target.path, token, f"bytes={suffix_start}-{total + 1}")
        clamp_range = validate_partial(response, clamped)[:4]
        check(clamp_range == (suffix_start, total - 1, total, etag) and clamped == suffix, "Wrong EOF clamp")
        statuses["eofClamp"] = response.status

    with closing(HTTPSConnection(target.netloc, timeout=60)) as connection:
        response, _, _ = fetch(connection, target.path, requested="bytes=0-4")
        check(response.status in (401, 403), f"Unauthenticated range received HTTP {response.status}")
        statuses["unauthenticated"] = response.status
    return total, etag, statuses


def transfer(target, token, destination, total, etag, concurrency):
    def lane(index):
        observations = []
        with closing(HTTPSConnection(target.netloc, timeout=60)) as connection, destination.open("r+b") as output:
            for block_start in range(index * MAX_RANGE_BYTES, total, concurrency * MAX_RANGE_BYTES):
                end = min(total, block_start + MAX_RANGE_BYTES) - 1
                next_byte = block_start
                output.seek(block_start)
                while next_byte <= end:
                    requested = f"bytes={next_byte}-{end}"
                    response, body, elapsed = fetch(connection, target.path, token, requested)
                    actual_start, actual_end, actual_total, actual_etag, heap = validate_partial(response, body)
                    check(actual_start == next_byte and actual_end <= end, f"Wrong byte interval for {requested}")
                    check(actual_total == total and actual_etag == etag, "The PDF revision changed during download")
                    output.write(body)
                    next_byte = actual_end + 1
                    observations.append((elapsed, heap))
        return observations

    started = perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        measurements = [measurement for group in pool.map(lane, range(concurrency)) for measurement in group]
    elapsed = perf_counter() - started
    milliseconds, heaps = zip(*measurements)
    return {
        "requestCount": len(measurements),
        "concurrency": concurrency,
        "wallMs": round(elapsed * 1000),
        "meanRangeMs": round(sum(milliseconds) / len(measurements), 1),
        "maxRangeMs": round(max(milliseconds), 1),
        "maxSampledApexHeapBytes": max(heaps),
        "apexCallouts": 0,
    }


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for data in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def pdf_details(path):
    details = {}
    if shutil.which("pdfinfo"):
        output = subprocess.check_output(["pdfinfo", path], text=True)
        pages = re.search(r"^Pages:\s+(\d+)$", output, re.MULTILINE)
        check(pages, "pdfinfo did not report a page count")
        details["pdfPages"] = int(pages[1])
    if shutil.which("pdfimages"):
        rows = subprocess.check_output(["pdfimages", "-list", path], text=True).splitlines()[2:]
        details["jpegPlacements"] = sum(row.split()[8] == "jpeg" for row in rows if row.strip())
    if shutil.which("pdffonts"):
        rows = subprocess.check_output(["pdffonts", path], text=True).splitlines()[2:]
        details["embeddedFonts"] = sorted({row.split()[0] for row in rows if row.strip() and row.split()[-5] == "yes"})
    return details


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest_version_id", help="Published ContentVersion or archive ID for the PDF manifest")
    parser.add_argument("--org", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--reference", type=Path, help="Existing PDF for an exact-byte comparison")
    parser.add_argument("--report", type=Path, help="Write verification evidence as JSON")
    parser.add_argument("--concurrency", type=int, default=6, choices=range(1, 17), metavar="1-16")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-zA-Z0-9]{15}(?:[a-zA-Z0-9]{3})?", args.manifest_version_id):
        parser.error("manifest_version_id must be a Salesforce record ID")
    if args.reference and args.reference.resolve() == args.output.resolve():
        parser.error("output and reference must be different files")

    base, token = org_auth(args.org)
    url = f"{base.rstrip('/')}/services/apexrest/portwood/pdf/{args.manifest_version_id}"
    target = urlsplit(url)
    check(target.scheme == "https" and not target.username and not target.password, "Expected an HTTPS org URL")
    reference_hash = sha256(args.reference) if args.reference else None
    total, etag, statuses = probe(target, token)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(dir=args.output.parent, prefix=f".{args.output.name}.", delete=False) as output:
        temporary = Path(output.name)
        output.truncate(total)
    try:
        measurements = transfer(target, token, temporary, total, etag, args.concurrency)
        digest = sha256(temporary)
        check(not reference_hash or digest == reference_hash, "Downloaded PDF differs from the reference")
        details = pdf_details(temporary)
        temporary.replace(args.output)
    finally:
        temporary.unlink(missing_ok=True)

    result = {
        "bytes": total,
        "sha256": digest,
        "referenceSha256": reference_hash,
        "matchesReference": digest == reference_hash if reference_hash else None,
        "probes": statuses,
        **measurements,
        **details,
    }
    evidence = json.dumps(result, indent=2)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(evidence + "\n")
    print(evidence)


if __name__ == "__main__":
    main()
