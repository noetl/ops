"""Registry client for the SLM MLOps template pack (noetl/ai-meta#146, G3).

The model / dataset / eval / release registry is a versioned, queryable catalog
index that the SLM stages write to: ``finetune`` registers a model + lineage +
metrics, ``dataset_build`` registers a dataset, ``eval`` registers an eval run,
``package`` registers a serving-ready release. Large artifact bytes (datasets,
adapter weights, eval reports) live in the object store (the noetl/ai-meta#104
result tier); a registry entry records *where* they live (``artifact_uri``) and
*how they were produced* (``metadata`` + ``lineage``).

All access is **server-mediated** (data-access-boundary.md): this client talks
to the NoETL server's ``/api/internal/registry/*`` + ``/api/internal/objects/*``
routes with the internal service-account token — workers / playbooks never touch
``noetl.registry`` or the object store directly.

Pure stdlib (Python 3.9+) so the runtime needs no extra package.

Env / args:
- ``server_url``  — e.g. ``http://noetl-server-rust:8082`` (in-cluster) or
  ``http://localhost:8082`` (kind port-forward). Falls back to
  ``NOETL_SERVER_URL``.
- ``token``       — the internal API token; falls back to
  ``NOETL_INTERNAL_API_TOKEN``.

The server must run with ``NOETL_REGISTRY_ENABLED=true`` for the registry routes
to exist (additive / default-off — noetl/ai-meta#146).
"""

import hashlib
import json
import os
import urllib.error
import urllib.parse
import urllib.request


class RegistryError(RuntimeError):
    pass


class RegistryClient:
    def __init__(self, server_url=None, token=None, timeout=60):
        self.server_url = (server_url or os.environ.get("NOETL_SERVER_URL") or "").rstrip("/")
        self.token = token or os.environ.get("NOETL_INTERNAL_API_TOKEN") or ""
        self.timeout = timeout
        if not self.server_url:
            raise RegistryError("server_url (or NOETL_SERVER_URL) is required")
        if not self.token:
            raise RegistryError("token (or NOETL_INTERNAL_API_TOKEN) is required")

    # ── low-level HTTP ──────────────────────────────────────────────────────

    def _request(self, method, path, *, body=None, raw_body=None, content_type=None, query=None):
        url = self.server_url + path
        if query:
            url += "?" + urllib.parse.urlencode({k: v for k, v in query.items() if v is not None})
        if raw_body is not None:
            data = raw_body
            ctype = content_type or "application/octet-stream"
        elif body is not None:
            data = json.dumps(body).encode("utf-8")
            ctype = "application/json"
        else:
            data = None
            ctype = None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.token)
        if ctype:
            req.add_header("Content-Type", ctype)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                payload = resp.read()
                return resp.status, payload
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()

    # ── artifact bytes (object store — the #104 substrate) ──────────────────

    def put_artifact(self, key, data, media_type="application/octet-stream"):
        """PUT raw artifact bytes at object-store ``key``; returns the server's
        ``{key, digest, bytes}`` ack. ``key`` is the canonical artifact key for
        the entry (see :func:`artifact_key`)."""
        if isinstance(data, str):
            data = data.encode("utf-8")
        status, payload = self._request(
            "PUT", "/api/internal/objects/" + key, raw_body=data, content_type=media_type
        )
        if status != 200:
            raise RegistryError("put_artifact %s failed: HTTP %s %s" % (key, status, payload[:300]))
        return json.loads(payload)

    def get_artifact(self, key):
        """GET artifact bytes back from the object store."""
        status, payload = self._request("GET", "/api/internal/objects/" + key)
        if status != 200:
            raise RegistryError("get_artifact %s failed: HTTP %s" % (key, status))
        return payload

    @staticmethod
    def artifact_key(kind, name, version, filename, tenant="default", project="default"):
        """The canonical object-store key an artifact lives at — mirrors the
        server's ``RegistryService::artifact_key``."""
        return "noetl/registry/%s/%s/%s/%s/%s/%s" % (tenant, project, kind, name, version, filename)

    # ── registry entries ────────────────────────────────────────────────────

    def register(self, kind, name, *, artifact_uri=None, artifact_digest=None,
                 artifact_bytes=None, media_type=None, metadata=None, lineage=None,
                 tags=None, tenant=None, project=None):
        """Register a new entry; the server assigns the next monotonic version.
        Returns the entry dict including its ``ref`` (``registry://…``) and
        ``version``."""
        body = {"kind": kind, "name": name}
        for k, v in (
            ("tenant", tenant), ("project", project), ("artifact_uri", artifact_uri),
            ("artifact_digest", artifact_digest), ("artifact_bytes", artifact_bytes),
            ("media_type", media_type), ("metadata", metadata), ("lineage", lineage),
            ("tags", tags),
        ):
            if v is not None:
                body[k] = v
        status, payload = self._request("POST", "/api/internal/registry/register", body=body)
        if status != 200:
            raise RegistryError("register %s/%s failed: HTTP %s %s" % (kind, name, status, payload[:300]))
        return json.loads(payload)

    def resolve(self, ref, tenant=None, project=None):
        """Resolve a ``registry://`` ref (supports a ``latest`` version) to its
        entry. Returns ``None`` on 404."""
        status, payload = self._request(
            "GET", "/api/internal/registry/resolve",
            query={"ref": ref, "tenant": tenant, "project": project},
        )
        if status == 404:
            return None
        if status != 200:
            raise RegistryError("resolve %s failed: HTTP %s %s" % (ref, status, payload[:300]))
        return json.loads(payload)

    def list(self, *, kind=None, name=None, tenant=None, project=None, limit=None):
        """List entries newest-first; returns the list of entry dicts."""
        status, payload = self._request(
            "GET", "/api/internal/registry/list",
            query={"kind": kind, "name": name, "tenant": tenant, "project": project, "limit": limit},
        )
        if status != 200:
            raise RegistryError("list failed: HTTP %s %s" % (status, payload[:300]))
        return json.loads(payload).get("entries", [])

    # ── convenience: store-then-register in one call ────────────────────────

    def put_and_register(self, kind, name, filename, data, *, media_type="application/octet-stream",
                         metadata=None, lineage=None, tags=None, tenant="default", project="default"):
        """The common stage shape: PUT the artifact, then register an entry
        pointing at it. The version is unknown until register returns, so the
        artifact is first PUT under a content key, then the entry records that
        key as ``artifact_uri``. Returns the registered entry."""
        import hashlib

        raw = data.encode("utf-8") if isinstance(data, str) else data
        digest = hashlib.sha256(raw).hexdigest()
        # Stage the artifact under a deterministic, version-independent key
        # (digest-addressed) so the PUT can precede version assignment.
        key = "noetl/registry/%s/%s/%s/%s/by-digest/%s/%s" % (
            tenant, project, kind, name, digest, filename)
        self.put_artifact(key, raw, media_type=media_type)
        return self.register(
            kind, name, artifact_uri=key, artifact_digest=digest, artifact_bytes=len(raw),
            media_type=media_type, metadata=metadata, lineage=lineage, tags=tags,
            tenant=tenant, project=project,
        )


# ── local file-backed backend (offline smoke / dev) ─────────────────────────

DEFAULT_TENANT = "default"
DEFAULT_PROJECT = "default"


def _build_ref(tenant, project, kind, name, version):
    """Fully-qualified URN, mirrors the server's ``build_ref``."""
    return "registry://%s/%s/%s/%s/%s" % (tenant, project, kind, name, version)


def _parse_ref(ref):
    """Parse a ``registry://`` URN, accepting the short
    (``registry://<kind>/<name>/<version>``) and fully-qualified
    (``registry://<tenant>/<project>/<kind>/<name>/<version>``) shapes. Returns
    ``(tenant, project, kind, name, version_or_None)`` (None == ``latest``)."""
    if not ref.startswith("registry://"):
        raise RegistryError("not a registry ref: %r" % ref)
    parts = ref[len("registry://"):].split("/")
    if len(parts) == 3:
        kind, name, ver = parts
        tenant, project = DEFAULT_TENANT, DEFAULT_PROJECT
    elif len(parts) == 5:
        tenant, project, kind, name, ver = parts
    else:
        raise RegistryError("malformed registry ref: %r" % ref)
    version = None if ver in ("latest", "") else int(ver)
    return tenant, project, kind, name, version


class LocalRegistryClient:
    """A file-backed mirror of the G3 server's registry semantics for offline /
    CPU smokes (``NOETL_REGISTRY_BACKEND=local``).  Same URN scheme, same
    monotonic version assignment, same digest-addressed artifact keys, same
    response dict shape — so the identical stage code runs against either backend
    and the only thing that changes for the production run is
    ``NOETL_REGISTRY_BACKEND=server`` + ``NOETL_SERVER_URL``.

    State lives under ``root`` (``NOETL_REGISTRY_LOCAL_DIR`` or
    ``~/.noetl/slm_registry``):  ``index.jsonl`` is the append-only entry log;
    ``objects/<key>`` holds artifact bytes.
    """

    def __init__(self, root=None):
        self.root = root or os.environ.get("NOETL_REGISTRY_LOCAL_DIR") \
            or os.path.join(os.path.expanduser("~"), ".noetl", "slm_registry")
        self.index_path = os.path.join(self.root, "index.jsonl")
        self.objects_dir = os.path.join(self.root, "objects")
        os.makedirs(self.objects_dir, exist_ok=True)

    # -- index IO -------------------------------------------------------------

    def _read_index(self):
        rows = []
        if os.path.isfile(self.index_path):
            with open(self.index_path) as fh:
                for line in fh:
                    line = line.strip()
                    if line:
                        rows.append(json.loads(line))
        return rows

    def _append_index(self, entry):
        with open(self.index_path, "a") as fh:
            fh.write(json.dumps(entry, sort_keys=True) + "\n")

    # -- artifacts ------------------------------------------------------------

    @staticmethod
    def artifact_key(kind, name, version, filename, tenant="default", project="default"):
        return "noetl/registry/%s/%s/%s/%s/%s/%s" % (tenant, project, kind, name, version, filename)

    def put_artifact(self, key, data, media_type="application/octet-stream"):
        if isinstance(data, str):
            data = data.encode("utf-8")
        dest = os.path.join(self.objects_dir, key)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as fh:
            fh.write(data)
        return {"key": key, "digest": hashlib.sha256(data).hexdigest(), "bytes": len(data)}

    def get_artifact(self, key):
        dest = os.path.join(self.objects_dir, key)
        if not os.path.isfile(dest):
            raise RegistryError("get_artifact %s failed: not found" % key)
        with open(dest, "rb") as fh:
            return fh.read()

    # -- entries --------------------------------------------------------------

    def register(self, kind, name, *, artifact_uri=None, artifact_digest=None,
                 artifact_bytes=None, media_type=None, metadata=None, lineage=None,
                 tags=None, tenant=None, project=None):
        if kind not in ("model", "dataset", "eval", "release"):
            raise RegistryError("unknown registry kind %r" % kind)
        tenant = tenant or DEFAULT_TENANT
        project = project or DEFAULT_PROJECT
        rows = self._read_index()
        versions = [r["version"] for r in rows
                    if r["tenant"] == tenant and r["project"] == project
                    and r["kind"] == kind and r["name"] == name]
        version = (max(versions) + 1) if versions else 1
        entry = {
            "ref": _build_ref(tenant, project, kind, name, version),
            "entry_id": len(rows) + 1,
            "tenant": tenant, "project": project, "kind": kind, "name": name,
            "version": version, "artifact_uri": artifact_uri,
            "artifact_digest": artifact_digest, "artifact_bytes": artifact_bytes,
            "media_type": media_type, "metadata": metadata or {},
            "lineage": lineage or [], "tags": tags or [],
        }
        self._append_index(entry)
        return entry

    def resolve(self, ref, tenant=None, project=None):
        t, p, kind, name, version = _parse_ref(ref)
        t = tenant or t
        p = project or p
        rows = [r for r in self._read_index()
                if r["tenant"] == t and r["project"] == p
                and r["kind"] == kind and r["name"] == name]
        if not rows:
            return None
        if version is None:
            return max(rows, key=lambda r: r["version"])
        for r in rows:
            if r["version"] == version:
                return r
        return None

    def list(self, *, kind=None, name=None, tenant=None, project=None, limit=None):
        rows = self._read_index()
        out = []
        for r in rows:
            if kind and r["kind"] != kind:
                continue
            if name and r["name"] != name:
                continue
            if tenant and r["tenant"] != tenant:
                continue
            if project and r["project"] != project:
                continue
            out.append(r)
        out.sort(key=lambda r: r["entry_id"], reverse=True)
        if limit:
            out = out[: int(limit)]
        return out

    def put_and_register(self, kind, name, filename, data, *, media_type="application/octet-stream",
                         metadata=None, lineage=None, tags=None, tenant="default", project="default"):
        raw = data.encode("utf-8") if isinstance(data, str) else data
        digest = hashlib.sha256(raw).hexdigest()
        key = "noetl/registry/%s/%s/%s/%s/by-digest/%s/%s" % (tenant, project, kind, name, digest, filename)
        self.put_artifact(key, raw, media_type=media_type)
        return self.register(
            kind, name, artifact_uri=key, artifact_digest=digest, artifact_bytes=len(raw),
            media_type=media_type, metadata=metadata, lineage=lineage, tags=tags,
            tenant=tenant, project=project)


def make_client():
    """Factory selecting the registry backend from the environment.

    - ``NOETL_REGISTRY_BACKEND=local`` → :class:`LocalRegistryClient` (offline
      smoke; no server needed).
    - otherwise (``server`` / unset) → the server-mediated
      :class:`RegistryClient` (needs ``NOETL_SERVER_URL`` +
      ``NOETL_INTERNAL_API_TOKEN`` and a server with
      ``NOETL_REGISTRY_ENABLED=true``).
    """
    backend = (os.environ.get("NOETL_REGISTRY_BACKEND") or "server").strip().lower()
    if backend == "local":
        return LocalRegistryClient()
    return RegistryClient()
