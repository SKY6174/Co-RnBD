import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const script = fileURLToPath(new URL('./build-scope.mjs', import.meta.url));
const policy = readFileSync(new URL('../build-scope.json', import.meta.url), 'utf8');
function fixture(fn) {
  const root = mkdtempSync(join(tmpdir(), 'build-scope-'));
  const git = (...args) => execFileSync('git', args, { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] }).toString().trim();
  const put = (path, body = 'fixture\n') => { mkdirSync(dirname(join(root, path)), { recursive: true }); writeFileSync(join(root, path), body); };
  const commit = () => { git('add', '-A'); git('commit', '-qm', 'fixture'); return git('rev-parse', 'HEAD'); };
  try {
    git('init', '-q', '--initial-branch=main');
    git('config', 'user.name', 'Build scope fixture'); git('config', 'user.email', 'fixture@example.invalid');
    put('.github/build-scope.json', policy); put('README.md'); put('src/app.js');
    put('docs/02-design/features/guide.md');
    const base = commit();
    const run = (head, env = {}, mode = 'vercel', cwd = root) => {
      const output = join(root, '..', `${root.split('/').at(-1)}-output`);
      const event = join(root, '..', `${root.split('/').at(-1)}-event`);
      try {
        writeFileSync(event, JSON.stringify(env.event ?? { before: base, after: head }));
        writeFileSync(output, '');
        const result = spawnSync(process.execPath, [script, mode], {
          cwd, encoding: 'utf8', env: { ...process.env, BUILD_SCOPE_FORCE: '',
            VERCEL_GIT_COMMIT_REF: 'main', VERCEL_GIT_PREVIOUS_SHA: base, VERCEL_GIT_COMMIT_SHA: head,
            GITHUB_SHA: head, GITHUB_EVENT_NAME: 'push', GITHUB_EVENT_PATH: event, GITHUB_OUTPUT: output,
            ...Object.fromEntries(Object.entries(env).filter(([key]) => key !== 'event')) },
        });
        return { ...result, output: readFileSync(output, 'utf8') };
      } finally { rmSync(output, { force: true }); rmSync(event, { force: true }); }
    };
    fn({ root, git, put, commit, base, run });
  } finally { rmSync(root, { recursive: true, force: true }); }
}
for (const path of ['AGENTS.md', 'README.md', 'docs/02-design/features/guide.md', '.agents/skills/example/SKILL.md', '.agents/skills/example/references/한글\n안내.md']) {
  test(`documentation skips app work: ${JSON.stringify(path)}`, () => fixture(({ put, commit, run }) => {
    put(path, 'updated\n'); const head = commit();
    assert.equal(run(head).status, 0);
    const ci = run(head, {}, 'github'); assert.equal(ci.status, 0); assert.match(ci.output, /^app=false\n/);
  }));
}
for (const path of ['src/instructions.md', 'public/helper/README.md', 'docs/manuals/release.md', 'docs/operations/data.json',
  'docs/unknown.md', 'unknown.md', 'vercel.json', 'package-lock.json', '.env.example', '.github/workflows/ci.yml',
  '.agents/skills/example/scripts/tool.mjs', 'src/한글\tname\n.js']) {
  test(`runtime or unclassified input builds: ${JSON.stringify(path)}`, () => fixture(({ put, commit, run }) => {
    put(path); assert.equal(run(commit()).status, 1);
  }));
}
test('all commits since the previous successful deployment are included', () => fixture(({ put, commit, run }) => {
  put('src/app.js', 'changed\n'); commit(); put('README.md', 'last commit is docs\n');
  assert.equal(run(commit()).status, 1);
}));
test('a multi-commit documentation push skips and a mixed push runs checks', () => fixture(({ put, commit, run, base }) => {
  put('AGENTS.md'); commit(); put('README.md', 'updated\n'); let head = commit();
  assert.match(run(head, { event: { before: base, after: head } }, 'github').output, /^app=false\n/);
  put('src/app.js', 'changed\n'); commit(); put('README.md', 'another update\n'); head = commit();
  assert.match(run(head, { event: { before: base, after: head } }, 'github').output, /^app=true\n/);
}));
test('renaming code into a documentation folder still builds', () => fixture(({ git, commit, run }) => {
  git('mv', 'src/app.js', 'docs/02-design/features/moved.md'); assert.equal(run(commit()).status, 1);
}));
test('deleting an allowlisted regular document can skip', () => fixture(({ root, commit, run }) => {
  rmSync(join(root, 'README.md')); assert.equal(run(commit()).status, 0);
}));
test('symlinks and executable documentation cannot skip', () => fixture(({ root, git, put, commit, run }) => {
  symlinkSync('../../../src/app.js', join(root, 'docs/02-design/features/link.md'));
  assert.equal(run(commit()).status, 1);
  rmSync(join(root, 'docs/02-design/features/link.md')); commit();
  put('README.md', 'changed\n'); git('add', 'README.md'); git('update-index', '--chmod=+x', 'README.md');
  git('commit', '-qm', 'executable mode'); assert.equal(run(git('rev-parse', 'HEAD')).status, 1);
}));
test('missing, zero, invalid, non-ancestor and same-SHA baselines build', () => fixture(({ put, git, commit, run }) => {
  put('README.md', 'updated\n'); const head = commit();
  const orphan = git('commit-tree', git('rev-parse', 'HEAD^{tree}'), '-m', 'unrelated root');
  for (const previous of ['', '0'.repeat(40), 'not-a-sha', 'f'.repeat(40), orphan, head]) {
    assert.equal(run(head, { VERCEL_GIT_PREVIOUS_SHA: previous }).status, 1, previous);
  }
}));
test('a shallow clone with unavailable successful history builds', () => fixture(({ root, put, commit, run }) => {
  put('AGENTS.md'); commit(); put('README.md', 'updated\n'); const head = commit();
  const clone = mkdtempSync(join(tmpdir(), 'build-scope-shallow-'));
  try {
    execFileSync('git', ['clone', '-q', '--depth=1', `file://${root}`, clone]);
    assert.equal(run(head, {}, 'vercel', clone).status, 1);
  } finally { rmSync(clone, { recursive: true, force: true }); }
}));
test('invalid policy and an explicit rebuild override keep the build', () => fixture(({ put, commit, run }) => {
  put('README.md', 'updated\n'); const head = commit();
  assert.equal(run(head, { BUILD_SCOPE_FORCE: '1' }).status, 1);
  put('.github/build-scope.json', '{}'); assert.equal(run(head).status, 1);
}));
test('the same decision works from a Vercel project subdirectory', () => fixture(({ root, put, commit, run }) => {
  put('README.md', 'updated\n'); const head = commit();
  const folder = join(root, 'site'); mkdirSync(folder);
  assert.equal(run(head, {}, 'vercel', folder).status, 0);
}));
for (const codeInPr of [false, true]) {
  test(`PR merge covers the entire PR and excludes new base-only code (${codeInPr})`, () => fixture(({ git, put, commit, run, base }) => {
    git('checkout', '-qb', 'feature'); put(codeInPr ? 'src/app.js' : 'AGENTS.md', 'PR change\n'); commit();
    put('README.md', 'final PR commit\n'); const prHead = commit();
    git('checkout', '-q', 'main'); put('src/base-only.js'); const prBase = commit();
    git('merge', '--no-ff', '-qm', 'fixture merge', 'feature'); const head = git('rev-parse', 'HEAD');
    const result = run(head, { GITHUB_EVENT_NAME: 'pull_request', event: { pull_request: { base: { sha: prBase }, head: { sha: prHead } } } }, 'github');
    assert.equal(result.status, 0); assert.match(result.output, new RegExp(`^app=${codeInPr}\\n`));
    assert.notEqual(prBase, base);
  }));
}
test('a PR head checkout uses the complete merge-base range', () => fixture(({ put, commit, run, base }) => {
  put('AGENTS.md'); commit(); put('README.md', 'updated\n'); const head = commit();
  const result = run(head, { GITHUB_EVENT_NAME: 'pull_request', event: { pull_request: { base: { sha: base }, head: { sha: head } } } }, 'github');
  assert.equal(result.status, 0); assert.match(result.output, /^app=false\n/);
}));
test('manual CI and mismatched checkout identities run full checks', () => fixture(({ put, commit, run }) => {
  put('README.md', 'updated\n'); const head = commit();
  assert.match(run(head, { GITHUB_EVENT_NAME: 'workflow_dispatch' }, 'github').output, /^app=true\n/);
  assert.match(run(head, { GITHUB_SHA: 'a'.repeat(40) }, 'github').output, /^app=true\n/);
}));
test('docs whitespace failures cannot report a passing lightweight CI gate', () => fixture(({ put, commit, run }) => {
  put('README.md', 'trailing spaces  \n'); assert.notEqual(run(commit(), {}, 'github').status, 0);
}));
test('policy changes cannot be classified as documentation', () => fixture(({ put, commit, run }) => {
  const value = JSON.parse(policy); value.documentationFiles.push('NEW-GUIDE.md');
  put('.github/build-scope.json', JSON.stringify(value)); assert.equal(run(commit()).status, 1);
}));
test('an invalid group cannot override the application decision', () => fixture(({ put, commit, run }) => {
  const value = JSON.parse(policy); value.groups = { app: ['no-match/'] };
  put('.github/build-scope.json', JSON.stringify(value)); const result = run(commit(), {}, 'github');
  assert.equal(result.status, 0); assert.match(result.output, /^app=true\n/);
  assert.match(result.output, /backend=true\n/); assert.match(result.output, /database=true\n/);
}));
test('required check groups are selected on source changes and kept on unknown ranges', () => fixture(({ put, commit, run }) => {
  const value = JSON.parse(policy); value.groups = { backend: ['backend/'], database: ['supabase/'] };
  put('.github/build-scope.json', JSON.stringify(value)); const previous = commit();
  put('supabase/migrations/fixture.sql'); const head = commit();
  const result = run(head, { event: { before: previous, after: head } }, 'github');
  assert.match(result.output, /^app=true\n/); assert.match(result.output, /backend=false\n/); assert.match(result.output, /database=true\n/);
  const unknown = run(head, { event: { before: '0'.repeat(40), after: head } }, 'github');
  assert.match(unknown.output, /backend=true\n/); assert.match(unknown.output, /database=true\n/);
}));
test('the existing UC-ANCHOR branch filter is retained without changing other projects', () => fixture(({ put, commit, run }) => {
  put('src/app.js', 'changed\n'); const head = commit();
  const value = JSON.parse(policy);
  assert.equal(run(head, { VERCEL_GIT_COMMIT_REF: 'feature' }).status, value.vercelBranches ? 0 : 1);
  assert.equal(run(head, { VERCEL_GIT_COMMIT_REF: 'staging' }).status, 1);
}));
