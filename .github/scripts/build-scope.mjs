import { execFileSync } from 'node:child_process';
import { appendFileSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

// No dependencies or network: this also runs before Vercel installs packages.
const mode = process.argv[2];
const sha = /^[a-f0-9]{40}$/;
let root;
let policy;
function git(...args) {
  return execFileSync('git', args, {
    cwd: root, timeout: 10_000, maxBuffer: 64 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  }).toString('utf8');
}
function validPath(path) {
  return typeof path === 'string' && path.length > 0 &&
    !path.split('/').some(part => ['', '.', '..'].includes(part));
}
function loadPolicy() {
  const value = JSON.parse(readFileSync(resolve(root, '.github/build-scope.json'), 'utf8'));
  if (value.version !== 1 || !Array.isArray(value.documentationFiles) ||
      !Array.isArray(value.documentationPrefixes) ||
      !value.documentationFiles.every(p => validPath(p) && p.endsWith('.md')) ||
      !value.documentationPrefixes.every(p => typeof p === 'string' && p.endsWith('/') && validPath(p.slice(0, -1))) ||
      (value.vercelBranches && (!Array.isArray(value.vercelBranches) || !value.vercelBranches.every(p => typeof p === 'string' && p)))) {
    throw new Error('Invalid build scope policy');
  }
  for (const [name, paths] of Object.entries(value.groups ?? {})) {
    if (!['backend', 'database'].includes(name) || !Array.isArray(paths) ||
        !paths.every(p => validPath(p.endsWith('/') ? p.slice(0, -1) : p))) {
      throw new Error('Invalid check group');
    }
  }
  return value;
}
function isDocumentation(path) {
  return path.endsWith('.md') && (policy.documentationFiles.includes(path) ||
    policy.documentationPrefixes.some(prefix => path.startsWith(prefix)));
}
function treeModes(revision) {
  return new Map(git('ls-tree', '-r', '-z', revision).split('\0').filter(Boolean).map(entry => {
    const tab = entry.indexOf('\t');
    return [entry.slice(tab + 1), entry.slice(0, tab).split(' ')[0]];
  }));
}
function compare(base, head) {
  if (![base, head].every(value => typeof value === 'string' && sha.test(value) && !/^0+$/.test(value)) ||
      git('rev-parse', 'HEAD').trim() !== head ||
      git('cat-file', '-t', base).trim() !== 'commit' ||
      git('cat-file', '-t', head).trim() !== 'commit') {
    throw new Error('Unverified comparison');
  }
  git('merge-base', '--is-ancestor', base, head);
  const paths = git('diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', base, head, '--').split('\0').filter(Boolean);
  // A same-SHA redeploy may be applying new environment settings.
  if (paths.length === 0) return { app: true, reason: 'empty comparison; rebuild allowed', paths, base, head };
  let docsOnly = paths.every(isDocumentation);
  if (docsOnly) {
    const before = treeModes(base), after = treeModes(head);
    docsOnly = paths.every(path => [before.get(path), after.get(path)].every(fileMode => !fileMode || fileMode === '100644'));
  }
  return { app: !docsOnly, reason: docsOnly ? 'allowlisted documentation only' : 'application or unclassified inputs changed', paths, base, head };
}
function githubRange() {
  const event = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8'));
  const head = process.env.GITHUB_SHA;
  if (process.env.GITHUB_EVENT_NAME === 'pull_request') {
    const pr = event.pull_request;
    const parents = git('show', '-s', '--format=%P', 'HEAD').trim().split(' ');
    if (parents.length === 2 && parents[1] === pr.head.sha) return [parents[0], head];
    if (head !== pr.head.sha || !sha.test(pr.base.sha)) throw new Error('Unverified PR checkout');
    return [git('merge-base', pr.base.sha, head).trim(), head];
  }
  if (process.env.GITHUB_EVENT_NAME === 'push' && event.after === head) return [event.before, head];
  throw new Error('Manual or unclassified event; run checks');
}
let result;
try {
  root = git('rev-parse', '--show-toplevel').trim();
  policy = loadPolicy();
  if (process.env.BUILD_SCOPE_FORCE === '1') throw new Error('Explicit full build');
  if (mode === 'vercel') {
    const branch = process.env.VERCEL_GIT_COMMIT_REF;
    if (branch && policy.vercelBranches && !policy.vercelBranches.includes(branch)) {
      result = { app: false, reason: 'existing branch deployment policy', paths: [] };
    } else {
      result = compare(process.env.VERCEL_GIT_PREVIOUS_SHA, process.env.VERCEL_GIT_COMMIT_SHA);
    }
  } else if (mode === 'github') {
    result = compare(...githubRange());
  } else {
    throw new Error('Unknown invocation');
  }
} catch {
  // Never turn missing history, policy, metadata or Git failures into a skip.
  result = { app: true, reason: 'comparison unavailable or full build requested' };
}
const groups = { backend: !result.paths, database: !result.paths, ...Object.fromEntries(Object.entries(policy?.groups ?? {}).map(([name, patterns]) => [name,
  !result.paths || result.paths.some(path => patterns.some(pattern => pattern.endsWith('/') ? path.startsWith(pattern) : path === pattern)),
])) };
if (!result.app) for (const name of Object.keys(groups)) groups[name] = false;
if (mode === 'github') {
  // A docs-only run still validates its changed text and reports a real gate result.
  if (!result.app && result.base) git('diff', '--check', result.base, result.head, '--');
  const output = Object.entries({ app: result.app, ...groups }).map(([key, value]) => `${key}=${value}\n`).join('');
  appendFileSync(process.env.GITHUB_OUTPUT, output);
}
console.log(JSON.stringify({ app: result.app, reason: result.reason, changedFiles: result.paths?.length ?? null, ...groups }));
// Vercel's convention is the inverse of a normal validation command.
process.exitCode = mode === 'vercel' ? (result.app ? 1 : 0) : mode === 'github' ? 0 : 1;
