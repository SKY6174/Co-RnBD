"""Delete paper PDFs that no longer belong to any paper or kept proceedings entry.

Run from the repository root AFTER app_private.purge_edition_personal_data(...).
Dry run by default: lists what would be deleted. Deletion needs --apply and a typed
confirmation. Uses the Supabase CLI login (no service key in files or env).

  python3 scripts/purge-paper-pdfs.py                 # dry run, production
  python3 scripts/purge-paper-pdfs.py --apply         # delete after confirmation
  python3 scripts/purge-paper-pdfs.py --remote=<ref>  # other target
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ["sh", str(ROOT / "scripts/supabase.sh")]
BATCH = 50
PATH_RE = re.compile(r"^[0-9a-f-]{36}/[0-9a-f-]{36}/[^/]+\.pdf$")

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--remote", default="lvtdnrmwunahgwutafhv", help="project ref (default: production)")
parser.add_argument("--local", action="store_true", help="target the local stack instead (testing)")
parser.add_argument("--apply", action="store_true", help="delete the listed files after confirmation")
parser.add_argument("--workdir", help="local test project folder (with --local)")
args = parser.parse_args()
if args.workdir:
    CLI = CLI + ["--workdir", args.workdir]
target = [] if args.local else [f"--remote={args.remote}"]


def run(cmd):
    result = subprocess.run(CLI + cmd, capture_output=True, text=True)
    if result.returncode:
        sys.exit("Supabase CLI failed:\n" + result.stderr[-2000:])
    return result.stdout


def query_rows(sql):
    raw = run(["db", "query", "--read-only", "-o", "json", *target, sql])
    return json.loads(raw[raw.find("{"):])["rows"]


paths = [row["path"] for row in query_rows("select path from app_private.paper_pdf_paths_to_purge()")]
bad = [p for p in paths if not PATH_RE.match(p)]
if bad:
    sys.exit(f"Unexpected object path(s), nothing deleted: {bad[:3]}")
where = "local stack" if args.local else f"project {args.remote}"
print(f"{len(paths)} PDF(s) in bucket paper-pdfs have no paper or proceedings entry ({where}).")
for path in paths[:10]:
    print("  -", path)
if len(paths) > 10:
    print(f"  ... and {len(paths) - 10} more")

if not args.apply or not paths:
    print("Dry run only. Nothing was deleted." if paths else "Nothing to delete.")
    sys.exit(0)

expected = f"DELETE {len(paths)} FILES"
if input(f'Type "{expected}" to delete them permanently: ').strip() != expected:
    sys.exit("Confirmation did not match. Nothing was deleted.")

deleted = 0
for i in range(0, len(paths), BATCH):
    batch = [f"ss:///paper-pdfs/{p}" for p in paths[i:i + BATCH]]
    run(["storage", "rm", "--experimental", *target, "--yes", *batch])
    deleted += len(batch)
    print(f"Deleted {deleted}/{len(paths)}")

left = query_rows("select count(*) as n from app_private.paper_pdf_paths_to_purge()")[0]["n"]
print(f"Remaining unreferenced PDFs: {left}")
