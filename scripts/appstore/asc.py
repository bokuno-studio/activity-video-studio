#!/usr/bin/env python3
"""App Store Connect API client (dependency-free: stdlib + openssl).

Auth comes from env vars (never printed):
  ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to AuthKey_<id>.p8)

Usage:
  asc.py get  <path>                e.g. get "/v1/apps?limit=1"
  asc.py app  <bundleId>            print the app's id + name
  asc.py builds <appId> [version]   list builds (optionally filter version)
  asc.py token                      print a short-lived JWT (for debugging)
"""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error

API = "https://api.appstoreconnect.apple.com"

def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def der_to_raw(der: bytes) -> bytes:
    # ECDSA DER (SEQ{INT r, INT s}) -> raw r||s (32 bytes each, P-256)
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    def read_int(i):
        assert der[i] == 0x02
        ln = der[i+1]
        v = der[i+2:i+2+ln]
        return v.lstrip(b"\x00").rjust(32, b"\x00"), i+2+ln
    r, i = read_int(i)
    s, _ = read_int(i)
    return r + s

def make_jwt() -> str:
    kid = os.environ["ASC_KEY_ID"]
    iss = os.environ["ASC_ISSUER_ID"]
    key_path = os.environ.get("ASC_KEY_PATH") or os.path.expanduser(
        f"~/.appstoreconnect/private_keys/AuthKey_{kid}.p8")
    header = {"alg": "ES256", "kid": kid, "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": iss, "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"}
    signing_input = (b64url(json.dumps(header, separators=(",", ":")).encode())
                     + "." + b64url(json.dumps(payload, separators=(",", ":")).encode()))
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path, "-binary"],
                         input=signing_input.encode(), capture_output=True, check=True).stdout
    return signing_input + "." + b64url(der_to_raw(der))

def request(method: str, path: str, body=None):
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + make_jwt())
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            txt = r.read().decode()
            return r.status, (json.loads(txt) if txt else {})
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode() or "{}")

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    cmd = sys.argv[1]
    if cmd == "token":
        print(make_jwt())
    elif cmd == "get":
        st, body = request("GET", sys.argv[2])
        print(st); print(json.dumps(body, indent=2, ensure_ascii=False))
    elif cmd == "app":
        bid = sys.argv[2]
        st, body = request("GET", f"/v1/apps?filter[bundleId]={bid}")
        for a in body.get("data", []):
            print(a["id"], a["attributes"]["name"], a["attributes"]["bundleId"])
    elif cmd == "builds":
        app_id = sys.argv[2]
        q = f"/v1/builds?filter[app]={app_id}&sort=-version&limit=10&include=preReleaseVersion"
        if len(sys.argv) > 3:
            q += f"&filter[preReleaseVersion.version]={sys.argv[3]}"
        st, body = request("GET", q)
        for b in body.get("data", []):
            at = b["attributes"]
            print(at.get("version"), at.get("processingState"), at.get("uploadedDate"))
    elif cmd == "version":
        app_id = sys.argv[2]
        v = editable_version(app_id)
        if v:
            print(v["id"], v["attributes"]["versionString"], v["attributes"]["appStoreState"])
        else:
            print("(no editable version)")
    elif cmd == "submit":
        # submit <app_id> <build_version> [notes_file]
        app_id, build_version = sys.argv[2], sys.argv[3]
        notes = open(sys.argv[4]).read() if len(sys.argv) > 4 else None
        submit_for_review(app_id, build_version, notes)
    elif cmd == "cancel":
        # cancel <app_id>  → cancel all blocking (non-terminal) reviewSubmissions
        cancel_blocking_submissions(sys.argv[2])
    else:
        print(__doc__); sys.exit(2)

# ---- submission helpers (write operations) ----

def _die(msg, st, body):
    sys.stderr.write(f"{msg}: HTTP {st}\n{json.dumps(body, indent=2, ensure_ascii=False)}\n")
    sys.exit(1)

def editable_version(app_id):
    st, body = request("GET",
        f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=MAC_OS&limit=10")
    if st != 200:
        _die("list versions failed", st, body)
    editable = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
                "METADATA_REJECTED", "INVALID_BINARY"}
    for v in body.get("data", []):
        if v["attributes"]["appStoreState"] in editable:
            return v
    return body.get("data", [None])[0]

def find_build(app_id, version):
    # `version` here is the build number (CFBundleVersion), as printed by the
    # `builds` command. Filter by filter[version] (build number), NOT by
    # preReleaseVersion.version (which is the marketing/short version string).
    st, body = request("GET",
        f"/v1/builds?filter[app]={app_id}&filter[version]={version}"
        f"&sort=-version&limit=1")
    if st != 200:
        _die("find build failed", st, body)
    data = body.get("data", [])
    return data[0]["id"] if data else None

def _list_submissions(app_id):
    st, body = request("GET",
        f"/v1/reviewSubmissions?filter[app]={app_id}&limit=50"
        f"&fields[reviewSubmissions]=state,submittedDate")
    if st != 200:
        _die("list reviewSubmissions failed", st, body)
    return body.get("data", [])

def cancel_blocking_submissions(app_id):
    """Cancel SUBMITTED reviewSubmissions that still hold the version. After a
    rejection the prior submission sits in UNRESOLVED_ISSUES and keeps ownership
    of the appStoreVersion, blocking a new submission (HTTP 409
    ITEM_PART_OF_ANOTHER_SUBMISSION). The ASC UI cancels it implicitly on
    re-submit; over the API we must do it explicitly. Drafts (never submitted)
    can't be canceled or deleted via the API, so they are reused, not canceled."""
    cancelable = {"WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"}
    for s in _list_submissions(app_id):
        sid, state = s["id"], s["attributes"].get("state")
        if state in cancelable:
            print(f"canceling submission {sid} (state={state})…")
            cst, cbody = request("PATCH", f"/v1/reviewSubmissions/{sid}",
                {"data": {"type": "reviewSubmissions", "id": sid,
                          "attributes": {"canceled": True}}})
            if cst not in (200, 204):
                _die(f"cancel submission {sid} failed", cst, cbody)

def find_or_create_draft(app_id):
    """Reuse an existing un-submitted draft (the API forbids deleting them), else
    create a fresh reviewSubmission."""
    for s in _list_submissions(app_id):
        if s["attributes"].get("submittedDate") is None \
           and s["attributes"].get("state") in (None, "READY_FOR_REVIEW", "UNRESOLVED_ISSUES"):
            print(f"reusing existing draft submission {s['id']}…")
            return s["id"]
    print("creating review submission…")
    st, body = request("POST", "/v1/reviewSubmissions",
        {"data": {"type": "reviewSubmissions",
                  "attributes": {"platform": "MAC_OS"},
                  "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
    if st not in (200, 201):
        _die("create reviewSubmission failed", st, body)
    return body["data"]["id"]

def submit_for_review(app_id, build_version, notes):
    cancel_blocking_submissions(app_id)
    ver = editable_version(app_id)
    if not ver:
        _die("no editable App Store version", 0, {})
    ver_id, state = ver["id"], ver["attributes"]["appStoreState"]
    print(f"version {ver['attributes']['versionString']} (id={ver_id}, state={state})")

    build_id = find_build(app_id, build_version)
    if not build_id:
        _die(f"build {build_version} not found (still processing?)", 0, {})
    print(f"attaching build {build_version} (id={build_id})…")
    st, body = request("PATCH", f"/v1/appStoreVersions/{ver_id}/relationships/build",
                       {"data": {"type": "builds", "id": build_id}})
    if st not in (200, 204):
        _die("attach build failed", st, body)

    if notes:
        print("setting App Review notes (sample files / how to test)…")
        st, body = request("GET", f"/v1/appStoreVersions/{ver_id}/appStoreReviewDetail")
        if st == 200 and body.get("data"):
            rid = body["data"]["id"]
            st, body = request("PATCH", f"/v1/appStoreReviewDetails/{rid}",
                {"data": {"type": "appStoreReviewDetails", "id": rid,
                          "attributes": {"notes": notes}}})
        else:
            st, body = request("POST", "/v1/appStoreReviewDetails",
                {"data": {"type": "appStoreReviewDetails",
                          "attributes": {"notes": notes},
                          "relationships": {"appStoreVersion":
                              {"data": {"type": "appStoreVersions", "id": ver_id}}}}})
        if st not in (200, 201):
            _die("set review notes failed", st, body)

    sub_id = find_or_create_draft(app_id)

    # Add the version as a submission item only if it isn't already one (a reused
    # draft from a prior partial run may already have it).
    ist, ibody = request("GET", f"/v1/reviewSubmissions/{sub_id}/items")
    if ist == 200 and ibody.get("data"):
        print("  version already on this submission — continuing.")
    else:
        print("adding version to submission…")
        st, body = request("POST", "/v1/reviewSubmissionItems",
            {"data": {"type": "reviewSubmissionItems",
                      "relationships": {
                          "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
                          "appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver_id}}}}})
        if st not in (200, 201):
            _die("add submission item failed", st, body)

    print("submitting for review…")
    st, body = request("PATCH", f"/v1/reviewSubmissions/{sub_id}",
        {"data": {"type": "reviewSubmissions", "id": sub_id,
                  "attributes": {"submitted": True}}})
    if st not in (200, 204):
        _die("submit failed", st, body)
    print("✅ submitted for review.")

if __name__ == "__main__":
    main()
