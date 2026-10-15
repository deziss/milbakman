#!/usr/bin/env python3
"""
Zero-dependency object copy between S3-compatible storage and local disk
(Python 3.9+ standard library only). Either side may be a bucket
(--src-endpoint/--src-bucket) or a local directory on any mounted filesystem
(--src-dir / --dst-dir): S3 -> S3, S3 -> disk (download), disk -> S3 (upload).

- Streams every object: nothing is buffered in memory or written to disk.
- Objects at or above --multipart-threshold-mib use multipart upload, so any
  object size up to the S3 maximum (5 TiB, 10,000 parts) is supported.
- Copies objects in parallel (--workers) and lists the source page by page,
  so buckets with millions of keys use constant memory.
- Skips objects already present with the same size (re-run to resume), retries
  transient errors, aborts failed multipart uploads, exits non-zero on failure.

Works with AWS S3, MinIO, Cloudflare R2, Ceph RGW, Wasabi, GCS (XML API with
HMAC keys), Aliyun OSS, Tencent COS and other SigV4 S3-compatible endpoints.
Credentials may be passed by flag or by env (SRC_/DST_ ACCESS_KEY/SECRET_KEY).
"""

import argparse
import concurrent.futures
import datetime
import hashlib
import hmac
import http.client
import math
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape as xml_escape

MiB = 1024 * 1024
TIMEOUT_SECONDS = 300            # per socket operation, not per whole transfer
MAX_PARTS = 10_000               # S3 multipart limit
MIN_PART_SIZE = 5 * MiB          # S3 minimum for every part except the last
MAX_OBJECT_SIZE = 5 * 1024 * 1024 * MiB  # 5 TiB
CHUNK = 1 * MiB
PARTIAL_SUFFIX = ".milbakman-partial"


class S3Error(RuntimeError):
    pass


def quote_s3(s):
    return urllib.parse.quote(str(s), safe="-_.~")


def part_size_for(size, min_part_size):
    """Smallest whole-MiB part size >= min_part_size that fits size in MAX_PARTS parts."""
    part = max(min_part_size, MIN_PART_SIZE, math.ceil(size / MAX_PARTS))
    return math.ceil(part / MiB) * MiB


def map_key(key, src_prefix, dst_prefix):
    sp = src_prefix.strip("/")
    dp = dst_prefix.strip("/")
    rel = key[len(sp) + 1:] if sp and key.startswith(sp + "/") else key
    return f"{dp}/{rel}" if dp else rel


def with_retries(fn, retries):
    """Run fn(), retrying network errors, timeouts, 5xx, 408 and 429 with backoff."""
    delay = 1.0
    for attempt in range(1, retries + 1):
        try:
            return fn()
        except urllib.error.HTTPError as e:
            if e.code < 500 and e.code not in (408, 429):
                raise
            err = e
        except (urllib.error.URLError, http.client.HTTPException, OSError) as e:
            err = e
        if attempt == retries:
            raise err
        time.sleep(delay)
        delay *= 2


class S3Client:
    def __init__(self, endpoint, access_key, secret_key, region="us-east-1", use_ssl=True):
        self.endpoint = endpoint.strip("/")
        if not self.endpoint.startswith(("http://", "https://")):
            proto = "https" if use_ssl else "http"
            self.endpoint = f"{proto}://{self.endpoint}"
        self.host = urllib.parse.urlparse(self.endpoint).netloc
        self.access_key = access_key
        self.secret_key = secret_key
        self.region = region

    # --- SigV4 ---------------------------------------------------------------
    def _sign(self, key, msg):
        return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

    def _signing_key(self, date_stamp):
        k_date = self._sign(("AWS4" + self.secret_key).encode("utf-8"), date_stamp)
        k_region = self._sign(k_date, self.region)
        k_service = self._sign(k_region, "s3")
        return self._sign(k_service, "aws4_request")

    def _request(self, method, bucket, key="", params=None, data=b"", headers=None, payload_hash=None):
        """Build a signed request. Streamed bodies (file objects) use UNSIGNED-PAYLOAD."""
        params = params or {}
        headers = headers or {}
        now = datetime.datetime.now(datetime.timezone.utc)
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        date_stamp = now.strftime("%Y%m%d")

        # Keys are used verbatim: "a//b" is a valid, distinct S3 key
        raw_uri = f"/{bucket}/{key}" if key else f"/{bucket}/"
        canonical_uri = urllib.parse.quote(raw_uri, safe="/-_.~")
        canonical_query = "&".join(
            f"{quote_s3(k)}={quote_s3(v)}" for k, v in sorted(params.items())
        )
        if payload_hash is None:
            payload_hash = hashlib.sha256(data).hexdigest()

        req_headers = {
            "host": self.host,
            "x-amz-date": amz_date,
            "x-amz-content-sha256": payload_hash,
        }
        for k, v in headers.items():
            req_headers[k.lower()] = str(v)
        names = sorted(req_headers)
        canonical_headers = "".join(f"{h}:{req_headers[h]}\n" for h in names)
        signed_headers = ";".join(names)

        canonical_request = "\n".join(
            [method, canonical_uri, canonical_query, canonical_headers, signed_headers, payload_hash]
        )
        scope = f"{date_stamp}/{self.region}/s3/aws4_request"
        string_to_sign = "\n".join(
            ["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()]
        )
        signature = hmac.new(self._signing_key(date_stamp), string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

        url = f"{self.endpoint}{canonical_uri}" + (f"?{canonical_query}" if canonical_query else "")
        body = data if method in ("PUT", "POST") else None
        req = urllib.request.Request(url, data=body, method=method)
        req.add_header(
            "Authorization",
            f"AWS4-HMAC-SHA256 Credential={self.access_key}/{scope}, SignedHeaders={signed_headers}, Signature={signature}",
        )
        for h, v in req_headers.items():
            req.add_header(h, v)
        return req

    @staticmethod
    def url(bucket, prefix):
        return f"s3://{bucket}/{prefix}"

    @staticmethod
    def _open(req):
        return urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS)

    # --- Operations ------------------------------------------------------------
    def iter_objects(self, bucket, prefix=""):
        """Yield {'key', 'size'} page by page (ListObjectsV2)."""
        token = None
        while True:
            params = {"list-type": "2", "max-keys": "1000"}
            if prefix:
                # Trailing "/" keeps "milvus-backups" from also matching "milvus-backups-old/..."
                params["prefix"] = prefix.strip("/") + "/"
            if token:
                params["continuation-token"] = token
            try:
                with self._open(self._request("GET", bucket, params=params)) as resp:
                    root = ET.fromstring(resp.read())
            except (urllib.error.URLError, http.client.HTTPException, OSError) as e:
                raise S3Error(f"cannot list bucket '{bucket}' at {self.endpoint}: {describe_error(e)}") from None

            truncated, token = False, None
            for elem in root:
                tag = elem.tag.rsplit("}", 1)[-1]
                if tag == "Contents":
                    key, size = None, 0
                    for child in elem:
                        ctag = child.tag.rsplit("}", 1)[-1]
                        if ctag == "Key":
                            key = child.text
                        elif ctag == "Size" and child.text:
                            size = int(child.text)
                    if key:
                        yield {"key": key, "size": size}
                elif tag == "IsTruncated":
                    truncated = (elem.text or "").strip().lower() == "true"
                elif tag == "NextContinuationToken":
                    token = elem.text
            if not (truncated and token):
                return

    def head_size(self, bucket, key):
        """Object size in bytes, or None if it does not exist."""
        try:
            with self._open(self._request("HEAD", bucket, key=key)) as resp:
                return int(resp.headers.get("Content-Length", -1))
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            raise

    def get(self, bucket, key, start=None, end=None):
        headers = {"Range": f"bytes={start}-{end}"} if start is not None else {}
        return self._open(self._request("GET", bucket, key=key, headers=headers))

    def put_stream(self, bucket, key, stream, length, params=None):
        req = self._request(
            "PUT", bucket, key=key, params=params, data=stream,
            headers={"Content-Length": str(length)}, payload_hash="UNSIGNED-PAYLOAD",
        )
        with self._open(req) as resp:
            resp.read()
            return resp.headers.get("ETag")

    def create_multipart(self, bucket, key):
        with self._open(self._request("POST", bucket, key=key, params={"uploads": ""})) as resp:
            root = ET.fromstring(resp.read())
        for elem in root.iter():
            if elem.tag.rsplit("}", 1)[-1] == "UploadId" and elem.text:
                return elem.text
        raise S3Error("CreateMultipartUpload returned no UploadId")

    def complete_multipart(self, bucket, key, upload_id, etags):
        parts = "".join(
            f"<Part><PartNumber>{n}</PartNumber><ETag>{xml_escape(etag)}</ETag></Part>"
            for n, etag in enumerate(etags, 1)
        )
        body = f"<CompleteMultipartUpload>{parts}</CompleteMultipartUpload>".encode("utf-8")
        req = self._request(
            "POST", bucket, key=key, params={"uploadId": upload_id}, data=body,
            headers={"Content-Type": "application/xml"},
        )
        with self._open(req) as resp:
            text = resp.read()
        # S3 may answer 200 with an <Error> body for CompleteMultipartUpload
        if b"<Error>" in text:
            raise S3Error(f"CompleteMultipartUpload failed: {text[:300].decode('utf-8', errors='ignore')}")

    def abort_multipart(self, bucket, key, upload_id):
        try:
            with self._open(self._request("DELETE", bucket, key=key, params={"uploadId": upload_id})) as resp:
                resp.read()
        except Exception:  # best effort; a bucket lifecycle rule cleans up the rest
            pass


class _Slice:
    """File-like view of `length` bytes of an open file from its current offset."""

    def __init__(self, f, length, status):
        self.f, self.left, self.status = f, length, status

    def read(self, n=-1):
        if self.left <= 0:
            return b""
        if n is None or n < 0 or n > self.left:
            n = self.left
        data = self.f.read(n)
        self.left -= len(data)
        return data

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.f.close()


class LocalStore:
    """A directory on any mounted filesystem, used in place of a bucket (bucket arg ignored)."""

    def __init__(self, root):
        self.root = os.path.abspath(root)

    def url(self, bucket, prefix):
        return os.path.join(self.root, prefix.strip("/"))

    def _path(self, key):
        parts = key.split("/")
        if key.startswith("/") or any(part in ("", ".", "..") for part in parts):
            raise S3Error(f"key '{key}' cannot be stored safely as a local file path")
        return os.path.join(self.root, *parts)

    def iter_objects(self, bucket, prefix=""):
        base = os.path.join(self.root, *[part for part in prefix.strip("/").split("/") if part])
        if not os.path.isdir(base):
            raise S3Error(f"directory not found: {base}")
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames.sort()
            for name in sorted(filenames):
                full = os.path.join(dirpath, name)
                if name.endswith(PARTIAL_SUFFIX) or os.path.islink(full) or not os.path.isfile(full):
                    continue
                yield {"key": os.path.relpath(full, self.root).replace(os.sep, "/"), "size": os.path.getsize(full)}

    def head_size(self, bucket, key):
        try:
            return os.path.getsize(self._path(key))
        except FileNotFoundError:
            return None

    def get(self, bucket, key, start=None, end=None):
        f = open(self._path(key), "rb")
        if start is None:
            return _Slice(f, os.fstat(f.fileno()).st_size, 200)
        f.seek(start)
        return _Slice(f, end - start + 1, 206)

    def put_stream(self, bucket, key, stream, length, params=None):
        """Write via a temp file + atomic rename, so partial files never look complete."""
        path = self._path(key)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f"{path}.{os.getpid()}.{threading.get_ident()}{PARTIAL_SUFFIX}"
        written = 0
        try:
            with open(tmp, "wb") as out:
                while True:
                    chunk = stream.read(CHUNK)
                    if not chunk:
                        break
                    out.write(chunk)
                    written += len(chunk)
            if written != length:
                raise S3Error(f"short read: got {written} of {length} bytes")
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return None


def copy_object(src, src_bucket, key, size, dst, dst_bucket, dst_key, threshold, min_part_size, retries):
    """Stream one object; returns a short description of how it was copied."""
    if size > MAX_OBJECT_SIZE:
        raise S3Error(f"object is {size} B; S3 maximum object size is 5 TiB")

    # Writing to local disk always streams the whole object into one file
    if size == 0 or size < threshold or isinstance(dst, LocalStore):
        def single():
            with src.get(src_bucket, key) as body:
                dst.put_stream(dst_bucket, dst_key, body, size)
        with_retries(single, retries)
        return "file" if isinstance(dst, LocalStore) else "single PUT"

    part_size = part_size_for(size, min_part_size)
    upload_id = with_retries(lambda: dst.create_multipart(dst_bucket, dst_key), retries)
    etags = []
    try:
        for number, start in enumerate(range(0, size, part_size), 1):
            end = min(start + part_size, size) - 1

            def upload_part(number=number, start=start, end=end):
                with src.get(src_bucket, key, start, end) as body:
                    if body.status != 206:
                        raise S3Error("source endpoint ignored the Range header; cannot stream parts")
                    return dst.put_stream(
                        dst_bucket, dst_key, body, end - start + 1,
                        params={"partNumber": str(number), "uploadId": upload_id},
                    )

            etag = with_retries(upload_part, retries)
            if not etag:
                raise S3Error(f"part {number} returned no ETag")
            etags.append(etag)
        with_retries(lambda: dst.complete_multipart(dst_bucket, dst_key, upload_id, etags), retries)
    except BaseException:
        dst.abort_multipart(dst_bucket, dst_key, upload_id)
        raise
    return f"multipart {len(etags)} x {part_size // MiB} MiB"


def describe_error(e):
    """One-line error: S3 <Code>/<Message> for HTTP errors, reason for network errors."""
    if isinstance(e, urllib.error.HTTPError):
        detail = ""
        try:
            root = ET.fromstring(e.read())
            fields = {el.tag.rsplit("}", 1)[-1]: (el.text or "").strip() for el in root}
            detail = " ".join(v for v in (fields.get("Code"), fields.get("Message")) if v)
        except Exception:
            pass
        return f"HTTP {e.code} {detail}".strip()
    if isinstance(e, urllib.error.URLError):
        return f"network error: {e.reason}"
    return " ".join(str(e).split()) or e.__class__.__name__


def migrate(src, src_bucket, src_prefix, dst, dst_bucket, dst_prefix, *, dry_run=False, workers=8,
            threshold=64 * MiB, min_part_size=64 * MiB, retries=3):
    print(f"[MIGRATOR] {src.url(src_bucket, src_prefix)} -> {dst.url(dst_bucket, dst_prefix)} "
          f"(workers={workers}, multipart >= {threshold // MiB} MiB)", flush=True)

    lock = threading.Lock()
    stats = {"seen": 0, "copied": 0, "skipped": 0, "bytes": 0}
    failures = []

    def log(line):
        with lock:
            print(line, flush=True)

    def task(obj):
        key, size = obj["key"], obj["size"]
        dst_key = map_key(key, src_prefix, dst_prefix)
        if key.endswith("/") and size == 0:
            return  # "folder" marker object, nothing to copy
        try:
            if with_retries(lambda: dst.head_size(dst_bucket, dst_key), retries) == size:
                with lock:
                    stats["skipped"] += 1
                log(f"  SKIPPED  {key} ({size} B, already present)")
                return
            how = copy_object(src, src_bucket, key, size, dst, dst_bucket, dst_key,
                              threshold, min_part_size, retries)
            with lock:
                stats["copied"] += 1
                stats["bytes"] += size
            log(f"  COPIED   {key} -> {dst_key} ({size} B, {how})")
        except Exception as e:
            msg = describe_error(e)
            with lock:
                failures.append((key, msg))
            log(f"  FAILED   {key}: {msg}")

    max_pending = workers * 4  # bound queued work so huge listings use constant memory
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        pending = set()
        try:
            for obj in src.iter_objects(src_bucket, prefix=src_prefix):
                stats["seen"] += 1
                if dry_run:
                    print(f"  DRY-RUN  {obj['key']} -> {map_key(obj['key'], src_prefix, dst_prefix)} ({obj['size']} B)")
                    stats["bytes"] += obj["size"]
                    continue
                pending.add(pool.submit(task, obj))
                if len(pending) >= max_pending:
                    _, pending = concurrent.futures.wait(pending, return_when=concurrent.futures.FIRST_COMPLETED)
            concurrent.futures.wait(pending)
        except KeyboardInterrupt:
            pool.shutdown(wait=False, cancel_futures=True)
            print("\n[MIGRATOR] Interrupted; re-run the same command to resume.", file=sys.stderr)
            raise

    mb = stats["bytes"] / MiB
    if dry_run:
        print(f"\n[MIGRATOR] Dry run: {stats['seen']} objects ({mb:.2f} MiB) would be considered.")
        return True
    if stats["seen"] == 0:
        print(f"[MIGRATOR] No objects found under {src.url(src_bucket, src_prefix)}")
        return True

    print(f"\n[MIGRATOR] {stats['seen']} objects: copied {stats['copied']} ({mb:.2f} MiB), "
          f"skipped {stats['skipped']} already present, failed {len(failures)}.")
    if failures:
        print("[MIGRATOR FAILED] Not copied (re-run to retry; finished objects are skipped):", file=sys.stderr)
        for key, err in failures:
            print(f"  - {key}: {err}", file=sys.stderr)
        return False
    print(f"[MIGRATOR SUCCESS] All objects are present in {dst.url(dst_bucket, dst_prefix)}")
    return True


def main():
    p = argparse.ArgumentParser(description="Copy objects between S3-compatible storage and local disk (any size)")
    p.add_argument("--src-endpoint", help="Source endpoint (host:port or URL)")
    p.add_argument("--src-bucket")
    p.add_argument("--src-dir", help="use a local directory as the source instead of a bucket")
    p.add_argument("--src-prefix", default="")
    p.add_argument("--src-access-key", default=os.environ.get("SRC_ACCESS_KEY"), help="or env SRC_ACCESS_KEY")
    p.add_argument("--src-secret-key", default=os.environ.get("SRC_SECRET_KEY"), help="or env SRC_SECRET_KEY")
    p.add_argument("--src-region", default="us-east-1")
    p.add_argument("--src-ssl", default="false", choices=["true", "false"])

    p.add_argument("--dst-endpoint", help="Destination endpoint (host:port or URL)")
    p.add_argument("--dst-bucket")
    p.add_argument("--dst-dir", help="use a local directory as the destination (download)")
    p.add_argument("--dst-prefix", default="", help="default: same as --src-prefix")
    p.add_argument("--dst-access-key", default=os.environ.get("DST_ACCESS_KEY"), help="or env DST_ACCESS_KEY")
    p.add_argument("--dst-secret-key", default=os.environ.get("DST_SECRET_KEY"), help="or env DST_SECRET_KEY")
    p.add_argument("--dst-region", default="us-east-1")
    p.add_argument("--dst-ssl", default="true", choices=["true", "false"])

    p.add_argument("--workers", type=int, default=8, help="objects copied in parallel (default 8)")
    p.add_argument("--multipart-threshold-mib", type=int, default=64,
                   help="use multipart upload for objects >= this size (default 64)")
    p.add_argument("--part-size-mib", type=int, default=64,
                   help="minimum part size; raised automatically to stay within 10,000 parts (default 64, min 5)")
    p.add_argument("--retries", type=int, default=3, help="attempts per request (default 3)")
    p.add_argument("--dry-run", action="store_true", help="list what would be copied")
    args = p.parse_args()

    for side in ("src", "dst"):
        local_dir, endpoint, bucket = (getattr(args, f"{side}_{n}") for n in ("dir", "endpoint", "bucket"))
        if local_dir and (endpoint or bucket):
            p.error(f"use either --{side}-dir or --{side}-endpoint/--{side}-bucket, not both")
        if not local_dir and not (endpoint and bucket):
            p.error(f"--{side}-endpoint and --{side}-bucket are required (or --{side}-dir)")
    if args.src_dir and args.dst_dir:
        p.error("at least one side must be S3 (use cp/rsync for disk-to-disk)")

    missing = []
    for side in ("src", "dst"):
        if not getattr(args, f"{side}_dir"):
            missing += [f"--{side}-{n}-key / {side.upper()}_{n.upper()}_KEY"
                        for n in ("access", "secret") if not getattr(args, f"{side}_{n}_key")]
    if missing:
        p.error("missing credentials: " + ", ".join(missing))
    if args.workers < 1 or args.retries < 1 or args.multipart_threshold_mib < 1:
        p.error("--workers, --retries and --multipart-threshold-mib must be >= 1")
    if args.part_size_mib < 5:
        p.error("--part-size-mib must be >= 5 (S3 minimum part size)")

    def store(side):
        if getattr(args, f"{side}_dir"):
            return LocalStore(getattr(args, f"{side}_dir"))
        return S3Client(getattr(args, f"{side}_endpoint"), getattr(args, f"{side}_access_key"),
                        getattr(args, f"{side}_secret_key"), getattr(args, f"{side}_region"),
                        getattr(args, f"{side}_ssl") == "true")

    src, dst = store("src"), store("dst")

    try:
        ok = migrate(
            src, args.src_bucket, args.src_prefix,
            dst, args.dst_bucket, args.dst_prefix or args.src_prefix,
            dry_run=args.dry_run, workers=args.workers,
            threshold=args.multipart_threshold_mib * MiB,
            min_part_size=args.part_size_mib * MiB,
            retries=args.retries,
        )
    except S3Error as e:
        print(f"[MIGRATOR ERROR] {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
