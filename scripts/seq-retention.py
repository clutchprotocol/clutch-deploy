"""Show or set Seq's retention policy. Run by scripts/seq-retention.sh inside a throwaway container
that shares the Seq container's network, so Seq is at http://127.0.0.1:80.

  python3 seq-retention.py check
  python3 seq-retention.py apply <days>

The admin password arrives in SEQ_PW (never an argument, never printed). Logs in like the Seq UI
does: POST api/users/login, keep the session cookie, send the returned CSRF token as
X-Seq-CsrfToken. "apply" adds a policy that deletes every log event older than <days>, unless a
policy that deletes everything at that age or sooner is already there.
"""
import http.cookiejar
import json
import os
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:80/"
jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
headers = {"Accept": "application/json", "Content-Type": "application/json"}


def call(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        with opener.open(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, None


def days_of(span):
    # .NET TimeSpan as JSON: "7.00:00:00" or "12:00:00".
    d, _, rest = span.partition(".") if "." in span.split(":")[0] else ("0", "", span)
    h, m, s = (float(x) for x in rest.split(":")[:3])
    return int(d) + (h + m / 60 + s / 3600) / 24


def main():
    mode = sys.argv[1]
    pw = os.environ.get("SEQ_PW", "")
    user = os.environ.get("SEQ_USER", "admin")
    code, me = call("POST", "api/users/login", {"Username": user, "Password": pw})
    if code != 200 or not me:
        print(f"  login as {user}: HTTP {code}. Nothing was changed.")
        return 1
    if me.get("CsrfToken"):
        headers["X-Seq-CsrfToken"] = me["CsrfToken"]
    print(f"  login as {user}: ok")

    code, policies = call("GET", "api/retentionpolicies/")
    if code != 200:
        print(f"  reading retention policies: HTTP {code}. Nothing was changed.")
        return 1
    print(f"  retention policies now: {len(policies)}")
    for p in policies:
        what = "everything" if p.get("RemovedSignalExpression") is None else "a filtered set"
        print(f"    deletes {what} from {p.get('DataSource', 'Stream')} after {p.get('RetentionTime')}")

    if mode == "check":
        print("  check only: nothing was changed.")
        return 0

    days = int(sys.argv[2])
    for p in policies:
        if (p.get("RemovedSignalExpression") is None
                and str(p.get("DataSource", "Stream")).lower() in ("stream", "0")
                and days_of(p["RetentionTime"]) <= days):
            print(f"  a policy already deletes all log events after {p['RetentionTime']}: nothing to add.")
            return 0

    code, tpl = call("GET", "api/retentionpolicies/template")
    if code != 200 or tpl is None:
        print(f"  reading the policy template: HTTP {code}. Nothing was changed.")
        return 1
    tpl["RetentionTime"] = f"{days}.00:00:00"
    tpl["RemovedSignalExpression"] = None
    tpl.pop("Id", None)
    code, made = call("POST", "api/retentionpolicies/", tpl)
    if code not in (200, 201):
        print(f"  creating the policy: HTTP {code}. Nothing was changed.")
        return 1
    print(f"  added: delete all log events after {made.get('RetentionTime') if made else tpl['RetentionTime']}")
    print("  Seq applies it in the background; the space comes back over the next hour or so.")
    return 0


sys.exit(main())
