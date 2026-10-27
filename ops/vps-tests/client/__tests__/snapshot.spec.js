import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it, beforeEach, afterEach } from 'vitest';

import {
  SnapshotError,
  captureSnapshot,
  isExcluded,
  matchesSecretPattern,
  readTreeState,
  toRepoRelative,
} from '../snapshot.mjs';
import { parseArgs, validateSpecs } from '../cli.mjs';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const config = JSON.parse(
  fs.readFileSync(path.resolve(testDir, '../../runtime.json'), 'utf8')
);

const git = (cwd, args) =>
  execFileSync('git', args, {
    cwd,
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: 'test',
      GIT_AUTHOR_EMAIL: 'test@example.com',
      GIT_COMMITTER_NAME: 'test',
      GIT_COMMITTER_EMAIL: 'test@example.com',
    },
  });

let repo;

beforeEach(() => {
  repo = fs.mkdtempSync(path.join(os.tmpdir(), 'vps-snap-test-'));
  git(repo, ['init', '-q', '-b', 'main']);
  fs.mkdirSync(path.join(repo, 'app/models'), { recursive: true });
  fs.mkdirSync(path.join(repo, 'spec/models'), { recursive: true });
  fs.writeFileSync(
    path.join(repo, 'app/models/account.rb'),
    'class Account; end\n'
  );
  fs.writeFileSync(
    path.join(repo, 'spec/models/account_spec.rb'),
    'describe Account\n'
  );
  git(repo, ['add', '-A']);
  git(repo, ['commit', '-qm', 'initial']);
});

afterEach(() => {
  fs.rmSync(repo, { recursive: true, force: true });
});

const capture = (explicitUntracked = []) => {
  const staging = fs.mkdtempSync(path.join(os.tmpdir(), 'vps-snap-stage-'));
  const result = captureSnapshot({
    repoRoot: repo,
    config,
    stagingRoot: staging,
    explicitUntracked,
    specs: ['spec/models/account_spec.rb'],
  });
  return { ...result, staging };
};

describe('snapshot selection', () => {
  it('submits modified working-tree bytes rather than committed HEAD content', () => {
    fs.writeFileSync(
      path.join(repo, 'app/models/account.rb'),
      'class Account; CHANGED = true; end\n'
    );

    const { manifest, staging } = capture();
    const entry = manifest.files.find(
      file => file.path === 'app/models/account.rb'
    );
    const staged = fs.readFileSync(
      path.join(staging, 'app/models/account.rb'),
      'utf8'
    );

    expect(staged).toContain('CHANGED');
    expect(entry.sha256).toBe(
      createHash('sha256')
        .update(fs.readFileSync(path.join(repo, 'app/models/account.rb')))
        .digest('hex')
    );
  });

  it('includes untracked specs under the source roots', () => {
    fs.writeFileSync(
      path.join(repo, 'spec/models/regression_spec.rb'),
      'describe "regression"\n'
    );

    const { manifest } = capture();

    expect(manifest.files.map(file => file.path)).toContain(
      'spec/models/regression_spec.rb'
    );
  });

  it('does not sweep in untracked files outside the source roots', () => {
    fs.writeFileSync(path.join(repo, 'notes.txt'), 'scratch\n');

    const { manifest } = capture();

    expect(manifest.files.map(file => file.path)).not.toContain('notes.txt');
  });

  it('submits an out-of-root file only when explicitly selected', () => {
    fs.writeFileSync(path.join(repo, 'notes.txt'), 'scratch\n');

    const { manifest } = capture(['notes.txt']);

    expect(manifest.files.map(file => file.path)).toContain('notes.txt');
  });

  it('records tracked deletions instead of silently keeping the old file', () => {
    fs.rmSync(path.join(repo, 'app/models/account.rb'));

    const { manifest } = capture();

    expect(manifest.deletions).toContain('app/models/account.rb');
    expect(manifest.files.map(file => file.path)).not.toContain(
      'app/models/account.rb'
    );
  });

  it('leaves the caller index, HEAD and dirty state untouched', () => {
    fs.writeFileSync(
      path.join(repo, 'app/models/account.rb'),
      'class Account; STAGED = true; end\n'
    );
    git(repo, ['add', 'app/models/account.rb']);
    fs.appendFileSync(path.join(repo, 'app/models/account.rb'), '# unstaged\n');
    const before = readTreeState(repo);

    capture();

    expect(readTreeState(repo)).toEqual(before);
    expect(before.dirty).toBe(true);
  });

  it('refuses an explicitly selected secret-bearing path by name', () => {
    fs.writeFileSync(path.join(repo, '.env'), 'SECRET=1\n');

    expect(() => capture(['.env'])).toThrow(SnapshotError);
  });

  it('refuses a selected path outside the repository', () => {
    expect(() => capture(['../outside.rb'])).toThrow(SnapshotError);
  });

  it('changes the files digest when a single source byte changes', () => {
    const first = capture().manifest.filesDigest;
    fs.appendFileSync(path.join(repo, 'app/models/account.rb'), '# tweak\n');
    const second = capture().manifest.filesDigest;

    expect(second).not.toBe(first);
  });

  it('keeps the digest stable for an unchanged tree so caches can be reused', () => {
    expect(capture().manifest.filesDigest).toBe(capture().manifest.filesDigest);
  });
});

describe('path and selector guards', () => {
  it('rejects traversal outside the repository', () => {
    expect(() => toRepoRelative('/repo', '/repo/../etc/passwd')).toThrow(
      SnapshotError
    );
  });

  it('treats tracked example env files as source, not secrets', () => {
    expect(
      matchesSecretPattern('.env.example', config.secretPathPatterns)
    ).toBe(false);
    expect(matchesSecretPattern('.env', config.secretPathPatterns)).toBe(true);
    expect(
      matchesSecretPattern(
        'config/credentials/production.key',
        config.secretPathPatterns
      )
    ).toBe(true);
  });

  it('excludes generated and dependency directories', () => {
    expect(isExcluded('node_modules/x.js', config.excludedPrefixes)).toBe(true);
    expect(isExcluded('public/vite-test/a.js', config.excludedPrefixes)).toBe(
      true
    );
    expect(isExcluded('app/models/account.rb', config.excludedPrefixes)).toBe(
      false
    );
  });

  it('rejects malformed spec selectors instead of altering what is tested', () => {
    expect(() => validateSpecs([])).toThrow(SnapshotError);
    expect(() => validateSpecs(['/abs/spec.rb'])).toThrow(SnapshotError);
    expect(() => validateSpecs(['../outside_spec.rb'])).toThrow(SnapshotError);
    expect(validateSpecs(['spec/models/account_spec.rb:42'])).toBe(true);
  });

  it('parses options without swallowing the spec list', () => {
    const options = parseArgs([
      '--include-untracked',
      'spec/support/a.rb',
      'spec/models/b_spec.rb',
    ]);

    expect(options.includeUntracked).toEqual(['spec/support/a.rb']);
    expect(options.specs).toEqual(['spec/models/b_spec.rb']);
  });

  it('rejects --include-untracked without a value', () => {
    expect(() => parseArgs(['--include-untracked'])).toThrow(SnapshotError);
  });
});
