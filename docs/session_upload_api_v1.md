# ScratchLab Session Upload API v1

This document describes the first client/backend contract for uploading completed ScratchLab session packages.

## Goal

- The app packages one completed session as one immutable ZIP archive.
- The backend issues a time-limited upload session and presigned object upload URL.
- The app uploads the ZIP from disk.
- The app confirms upload completion.
- The backend verifies the object, queues ingestion, and keeps the raw object private.

## Upload Flow

1. App validates the local session package.
2. App creates `session.zip`.
3. App calls `POST /upload-sessions`.
4. Backend returns a backend session ID, object key, and presigned `PUT` URL.
5. App uploads the ZIP directly to object storage with `PUT`.
6. App calls `POST /upload-sessions/{id}/complete`.
7. Backend verifies the uploaded object and queues ingestion.

## POST /upload-sessions

Create a backend upload session for one ZIP archive.

### Request

```json
{
  "dj_id": "dj_123",
  "session_name": "Baby Scratch 90 BPM",
  "file_size_bytes": 123456789,
  "sha256": "6d4d0e3c..."
}
```

### Response

```json
{
  "session_id": "sess_abc123",
  "object_key": "raw/dj_123/2026/04/18/sess_abc123/session.zip",
  "upload_url": "https://storage.example.com/...",
  "expires_at": "2026-04-18T12:30:00Z"
}
```

### Optional response extension

If object storage requires additional headers, the backend may also return:

```json
{
  "upload_headers": {
    "x-amz-server-side-encryption": "AES256"
  }
}
```

Clients should treat `upload_headers` as optional.

## POST /upload-sessions/{id}/complete

Tell the backend that the client finished uploading the ZIP.

### Request

```json
{
  "bytes_uploaded": 123456789,
  "sha256": "6d4d0e3c..."
}
```

### Success behavior

- Backend verifies the uploaded object exists at the issued `object_key`.
- Backend verifies object size and checksum when available.
- Backend marks the upload session as complete.
- Backend queues ingestion or downstream processing.

### Idempotency

- This endpoint should be idempotent.
- Repeating the same completion request for the same uploaded object should return success.
- If the object is missing, the backend should return a retryable failure.

## Optional GET /upload-sessions/{id}/status

This endpoint is optional for v1. If implemented, it should return the backend session state so the client can poll or recover after relaunch.

### Example response

```json
{
  "session_id": "sess_abc123",
  "state": "processing"
}
```

## Backend Semantics

- Backend generates the storage `object_key`.
- Backend issues one presigned `PUT` URL for one immutable ZIP object.
- The presigned URL is time-limited.
- Object storage remains private.
- Backend must not trust client completion without checking the object exists.
- Ingestion begins only after successful completion confirmation.
- Once accepted, the raw uploaded ZIP is immutable.

## Client Semantics

- Client uploads from a local file URL, not an in-memory blob.
- Client must not delete the local raw session before backend confirmation succeeds.
- Client may retry `POST /upload-sessions` or `POST /complete` on transient failures.
- If the presigned URL expires before upload finishes, the client should request a new upload session.

## Retention Assumptions

- The client keeps the raw local session and the generated ZIP until backend confirmation succeeds.
- After confirmation, the session is treated as cloud-backed.
- Local cleanup remains user-controlled in v1.
