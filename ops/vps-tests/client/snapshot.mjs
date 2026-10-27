// Working-tree snapshot for the maintained VPS backend test route (WOOT-32).
//
// Reads the caller's on-disk bytes - staged, unstaged and selected untracked -
// into a private scratch copy, then derives every identity from that immutable
// copy. The caller's index, HEAD, branch and files are never modified: only
// read-only git commands are used.

import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

export class SnapshotError extends Error {}

export function git(repoRoot, args) {
  const result = spawnSync('git', args, {
    cwd: repoRoot,
    encoding: 'buffer',
    maxBuffer: 256 * 1024 * 1024,
  });
  if (result.error) throw new SnapshotError(`git ${args[0]} failed: ${result.error.message}`);
  if (result.status !== 0) {
    const stderr = result.stderr.toString('utf8').trim();
    throw new SnapshotError(`git ${args.join(' ')} exited ${result.status}: ${stderr}`);
  }
  return result.stdout;
}

const splitZ = buffer =>
  buffer
    .toString('utf8')
    .split('\0')
    .filter(entry => entry.length > 0);

export function sha256File(absolutePath) {
  return createHash('sha256').update(fs.readFileSync(absolutePath)).digest('hex');
}

export function sha256Buffer(buffer) {
  return createHash('sha256').update(buffer).digest('hex');
}

// A path is inside the repository only if it stays under the root once resolved.
// Rejects `..` traversal and absolute paths pointing elsewhere.
export function toRepoRelative(repoRoot, candidate) {
  const absolute = path.resolve(repoRoot, candidate);
  const relative = path.relative(repoRoot, absolute);
  if (relative === '' || relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new SnapshotError(`path is outside the repository: ${candidate}`);
  }
  return relative.split(path.sep).join('/');
}

export function isExcluded(relativePath, excludedPrefixes) {
  return excludedPrefixes.some(prefix => relativePath === prefix || relativePath.startsWith(prefix));
}

export function matchesSecretPattern(relativePath, secretPathPatterns) {
  return secretPathPatterns.some(pattern => new RegExp(pattern).test(relativePath));
}

export function isUnderSourceRoots(relativePath, sourceRoots) {
  return sourceRoots.some(root => relativePath === root || relativePath.startsWith(`${root}/`));
}

/**
 * Decide exactly which paths are transferred.
 *
 * Tracked files are source by definition and are always included, so the
 * snapshot can honestly claim to be the submitted tree. Untracked files are
 * only auto-included under the documented source roots; anything else must be
 * named explicitly. A secret-bearing path is refused by name rather than
 * silently dropped.
 */
export function selectPaths(repoRoot, config, explicitUntracked = []) {
  const { sourceRoots, excludedPrefixes, secretPathPatterns } = config;

  const tracked = splitZ(git(repoRoot, ['ls-files', '-z']));
  const untracked = splitZ(git(repoRoot, ['ls-files', '-z', '--others', '--exclude-standard']));

  const included = new Map();
  const deletions = [];

  for (const relativePath of tracked) {
    if (matchesSecretPattern(relativePath, secretPathPatterns)) {
      throw new SnapshotError(
        `refusing to snapshot: tracked path looks secret-bearing: ${relativePath}`
      );
    }
    const absolute = path.join(repoRoot, relativePath);
    if (!fs.existsSync(absolute)) {
      deletions.push(relativePath); // honor tracked deletions in the working tree
      continue;
    }
    included.set(relativePath, 'tracked');
  }

  for (const relativePath of untracked) {
    if (isExcluded(relativePath, excludedPrefixes)) continue;
    if (!isUnderSourceRoots(relativePath, sourceRoots)) continue;
    if (matchesSecretPattern(relativePath, secretPathPatterns)) continue;
    included.set(relativePath, 'untracked');
  }

  for (const candidate of explicitUntracked) {
    const relativePath = toRepoRelative(repoRoot, candidate);
    if (matchesSecretPattern(relativePath, secretPathPatterns)) {
      throw new SnapshotError(
        `refusing to snapshot: --include-untracked path looks secret-bearing: ${relativePath}`
      );
    }
    if (isExcluded(relativePath, excludedPrefixes)) {
      throw new SnapshotError(
        `refusing to snapshot: --include-untracked path is an excluded artifact path: ${relativePath}`
      );
    }
    const absolute = path.join(repoRoot, relativePath);
    if (!fs.existsSync(absolute)) {
      throw new SnapshotError(`--include-untracked path does not exist: ${relativePath}`);
    }
    if (fs.statSync(absolute).isDirectory()) {
      for (const nested of walkDirectory(repoRoot, relativePath)) included.set(nested, 'selected');
    } else {
      included.set(relativePath, 'selected');
    }
  }

  return {
    files: [...included.entries()]
      .map(([relativePath, origin]) => ({ path: relativePath, origin }))
      .sort((a, b) => (a.path < b.path ? -1 : 1)),
    deletions: deletions.sort(),
  };
}

function* walkDirectory(repoRoot, relativeDir) {
  for (const entry of fs.readdirSync(path.join(repoRoot, relativeDir), { withFileTypes: true })) {
    const child = `${relativeDir}/${entry.name}`;
    if (entry.isDirectory()) yield* walkDirectory(repoRoot, child);
    else yield child;
  }
}

// Cheap identity of the caller's state, compared before and after capture so a
// tree edited mid-capture is reported instead of mixing revisions, and so we can
// prove a dirty input stayed dirty in exactly the same way.
export function readTreeState(repoRoot) {
  const statusOutput = git(repoRoot, ['status', '--porcelain=v1', '-z']);
  return {
    head: git(repoRoot, ['rev-parse', 'HEAD']).toString('utf8').trim(),
    branch: git(repoRoot, ['rev-parse', '--abbrev-ref', 'HEAD']).toString('utf8').trim(),
    dirty: statusOutput.length > 0,
    status: sha256Buffer(statusOutput),
    indexDigest: sha256Buffer(git(repoRoot, ['diff', '--cached', '--raw', '-z'])),
  };
}

export function fileIdentity(absolutePath) {
  const stats = fs.lstatSync(absolutePath);
  if (stats.isSymbolicLink()) {
    const target = fs.readlinkSync(absolutePath);
    return { type: 'symlink', target, sha256: sha256Buffer(Buffer.from(target)) };
  }
  return {
    type: 'file',
    mode: stats.mode & 0o111 ? '755' : '644',
    size: stats.size,
    sha256: sha256File(absolutePath),
  };
}

/**
 * Copy selected bytes into `stagingRoot` and return the manifest describing
 * exactly what was captured.
 */
export function captureSnapshot({ repoRoot, config, stagingRoot, explicitUntracked, specs }) {
  const before = readTreeState(repoRoot);
  const selection = selectPaths(repoRoot, config, explicitUntracked);

  const entries = [];
  for (const { path: relativePath, origin } of selection.files) {
    const source = path.join(repoRoot, relativePath);
    const destination = path.join(stagingRoot, relativePath);
    fs.mkdirSync(path.dirname(destination), { recursive: true });

    const identity = fileIdentity(source);
    if (identity.type === 'symlink') {
      fs.symlinkSync(identity.target, destination);
    } else {
      fs.copyFileSync(source, destination);
      fs.chmodSync(destination, identity.mode === '755' ? 0o755 : 0o644);
    }
    entries.push({ path: relativePath, origin, ...identity });
  }

  const after = readTreeState(repoRoot);
  if (before.status !== after.status || before.head !== after.head) {
    throw new SnapshotError(
      'working tree changed while the snapshot was being captured; rerun so one revision is submitted'
    );
  }

  const manifest = {
    schema: 'chatwoot.vps-tests.manifest/1',
    capturedAt: new Date().toISOString(),
    source: {
      head: after.head,
      branch: after.branch,
      dirty: after.dirty,
      statusDigest: after.status,
      indexDigest: after.indexDigest,
    },
    specs,
    fileCount: entries.length,
    deletions: selection.deletions,
    files: entries,
  };
  manifest.filesDigest = sha256Buffer(
    Buffer.from(entries.map(e => `${e.path}\0${e.sha256}\0${e.mode ?? e.type}`).join('\n'))
  );
  return { manifest, callerState: after };
}
