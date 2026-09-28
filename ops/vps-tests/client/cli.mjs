// CLI for the maintained VPS backend test route (WOOT-32). See bin/vps-rspec.

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { captureSnapshot, git, readTreeState, sha256File, SnapshotError } from './snapshot.mjs';
import {
  MISSING_SSH_HINT,
  TransportError,
  ensureKnownHost,
  fetchRemoteFile,
  runScp,
  runSsh,
  scanHostFingerprint,
  which,
} from './transport.mjs';

const CLIENT_DIR = path.dirname(fileURLToPath(import.meta.url));
export const OPS_DIR = path.dirname(CLIENT_DIR);

export const USAGE = `Usage: bin/vps-rspec [options] <spec selector>...

Runs Chatwoot backend specs on the maintained VPS route against your actual
working tree, including uncommitted changes.

Options:
  --preflight               Check transport and runtime readiness, run nothing.
  --dry-run                 Build and report the snapshot manifest, transfer nothing.
  --include-untracked PATH  Also submit an untracked path outside the source roots.
  --json                    Emit the receipt as JSON on stdout.
  -h, --help                Show this help.

Examples:
  bin/vps-rspec spec/models/account_spec.rb
  bin/vps-rspec spec/models/account_spec.rb:42
  bin/vps-rspec --include-untracked spec/support/my_helper.rb spec/models/account_spec.rb
`;

export function parseArgs(argv) {
  const options = { specs: [], includeUntracked: [], preflight: false, dryRun: false, json: false, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--preflight') options.preflight = true;
    else if (arg === '--dry-run') options.dryRun = true;
    else if (arg === '--json') options.json = true;
    else if (arg === '-h' || arg === '--help') options.help = true;
    else if (arg === '--include-untracked') {
      const value = argv[i + 1];
      if (!value || value.startsWith('--')) {
        throw new SnapshotError('--include-untracked requires a path argument');
      }
      options.includeUntracked.push(value);
      i += 1;
    } else if (arg.startsWith('--')) {
      throw new SnapshotError(`unknown option: ${arg}`);
    } else {
      options.specs.push(arg);
    }
  }
  return options;
}

// Spec selectors reach the runner as argv entries, never as shell text, but we
// still refuse obviously malformed input rather than quietly testing something
// other than what was asked for.
export function validateSpecs(specs) {
  if (specs.length === 0) {
    throw new SnapshotError('no spec selector given; pass at least one spec path');
  }
  for (const spec of specs) {
    const filePart = spec.split(':')[0];
    if (spec.startsWith('-')) throw new SnapshotError(`invalid spec selector: ${spec}`);
    if (path.isAbsolute(filePart)) {
      throw new SnapshotError(`spec selector must be repository-relative: ${spec}`);
    }
    if (filePart.split('/').includes('..')) {
      throw new SnapshotError(`spec selector must stay inside the repository: ${spec}`);
    }
  }
  return true;
}

export function loadConfig() {
  return JSON.parse(fs.readFileSync(path.join(OPS_DIR, 'runtime.json'), 'utf8'));
}

export function repoRoot() {
  return git(process.cwd(), ['rev-parse', '--show-toplevel']).toString('utf8').trim();
}

export function runnerIdentity() {
  const runner = path.join(OPS_DIR, 'runner.sh');
  return { path: 'ops/vps-tests/runner.sh', sha256: sha256File(runner) };
}

function preflight(config, { json }) {
  const checks = [];
  const sshPath = which('ssh');
  const scpPath = which('scp');
  checks.push({ name: 'ssh client', ok: Boolean(sshPath), detail: sshPath ?? MISSING_SSH_HINT });
  checks.push({ name: 'scp client', ok: Boolean(scpPath), detail: scpPath ?? 'not installed' });

  const identity = path.join(os.homedir(), '.ssh', 'id_ed25519');
  checks.push({
    name: 'ssh identity',
    ok: fs.existsSync(identity),
    detail: fs.existsSync(identity) ? identity : `missing ${identity}`,
  });

  const reachable = probeEndpoint(config);
  checks.push({ name: `endpoint ${config.transport.host}:${config.transport.port}`, ok: reachable.ok, detail: reachable.detail });

  if (sshPath) {
    const host = scanHostFingerprint(config);
    checks.push({
      name: 'host key fingerprint',
      ok: host.ok,
      detail: host.ok ? host.fingerprint : `expected ${config.transport.hostKeyFingerprint}, got ${host.fingerprint ?? host.reason}`,
    });
    const auth = runSsh(config, ['id', '-un']);
    checks.push({
      name: 'authenticated command',
      ok: auth.status === 0,
      detail: auth.status === 0 ? `remote user ${auth.stdout.trim()}` : (auth.stderr || '').trim(),
    });
  } else {
    checks.push({ name: 'authenticated command', ok: false, detail: 'skipped: no ssh client' });
  }

  const ok = checks.every(check => check.ok);
  if (json) {
    process.stdout.write(`${JSON.stringify({ preflight: checks, ok }, null, 2)}\n`);
  } else {
    for (const check of checks) {
      process.stdout.write(`${check.ok ? 'ok  ' : 'FAIL'}  ${check.name}: ${check.detail}\n`);
    }
    process.stdout.write(ok ? '\npreflight passed\n' : '\npreflight failed\n');
  }
  return ok ? 0 : 1;
}

// Node-only reachability probe so --preflight stays useful before the platform
// delivers the ssh client.
function probeEndpoint(config) {
  const result = spawnSync(
    process.execPath,
    [
      '-e',
      `const net=require('net');const s=net.connect({host:process.argv[1],port:Number(process.argv[2])});
       s.setTimeout(8000);
       s.on('data',d=>{process.stdout.write(d.toString().trim());s.destroy();process.exit(0);});
       s.on('timeout',()=>{process.stderr.write('timeout');process.exit(1);});
       s.on('error',e=>{process.stderr.write(e.message);process.exit(1);});`,
      config.transport.host,
      String(config.transport.port),
    ],
    { encoding: 'utf8', timeout: 20000 }
  );
  return result.status === 0
    ? { ok: true, detail: result.stdout.trim() }
    : { ok: false, detail: (result.stderr || 'unreachable').trim() };
}

function buildSnapshot(config, options, root) {
  const stagingRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'vps-rspec-'));
  const snapshotRoot = path.join(stagingRoot, 'snapshot');
  fs.mkdirSync(snapshotRoot);

  const stateBefore = readTreeState(root);
  const { manifest } = captureSnapshot({
    repoRoot: root,
    config,
    stagingRoot: snapshotRoot,
    explicitUntracked: options.includeUntracked,
    specs: options.specs,
  });
  manifest.runner = runnerIdentity();

  const manifestPath = path.join(stagingRoot, 'manifest.json');
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

  const archivePath = path.join(stagingRoot, 'snapshot.tar.gz');
  const tar = spawnSync('tar', ['-czf', archivePath, '-C', snapshotRoot, '.'], { encoding: 'utf8' });
  if (tar.status !== 0) throw new SnapshotError(`tar failed: ${tar.stderr}`);

  manifest.archiveSha256 = sha256File(archivePath);
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

  // Prove we did not disturb the caller's tree while capturing it.
  const stateAfter = readTreeState(root);
  const untouched =
    stateBefore.head === stateAfter.head &&
    stateBefore.status === stateAfter.status &&
    stateBefore.indexDigest === stateAfter.indexDigest;
  if (!untouched) {
    throw new SnapshotError('client modified the caller working tree; refusing to continue');
  }

  return { stagingRoot, snapshotRoot, manifestPath, archivePath, manifest };
}

export async function main(argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    process.stderr.write(`${error.message}\n\n${USAGE}`);
    return 2;
  }
  if (options.help) {
    process.stdout.write(USAGE);
    return 0;
  }

  const config = loadConfig();
  if (options.preflight) return preflight(config, options);

  try {
    validateSpecs(options.specs);
  } catch (error) {
    process.stderr.write(`${error.message}\n\n${USAGE}`);
    return 2;
  }

  const root = repoRoot();
  let prepared;
  try {
    prepared = buildSnapshot(config, options, root);
  } catch (error) {
    if (error instanceof SnapshotError) {
      process.stderr.write(`snapshot refused: ${error.message}\n`);
      return 2;
    }
    throw error;
  }

  const { manifest, stagingRoot, manifestPath, archivePath } = prepared;

  if (options.dryRun) {
    const summary = {
      dryRun: true,
      head: manifest.source.head,
      branch: manifest.source.branch,
      dirty: manifest.source.dirty,
      fileCount: manifest.fileCount,
      deletions: manifest.deletions.length,
      filesDigest: manifest.filesDigest,
      archiveSha256: manifest.archiveSha256,
      runner: manifest.runner,
      specs: manifest.specs,
      selected: manifest.files.filter(file => file.origin !== 'tracked').map(file => file.path),
    };
    process.stdout.write(
      options.json ? `${JSON.stringify(summary, null, 2)}\n` : formatDryRun(summary)
    );
    fs.rmSync(stagingRoot, { recursive: true, force: true });
    return 0;
  }

  if (!which('ssh') || !which('scp')) {
    process.stderr.write(`${MISSING_SSH_HINT}\n\nRun bin/vps-rspec --preflight for details.\n`);
    fs.rmSync(stagingRoot, { recursive: true, force: true });
    return 3;
  }

  try {
    return await execute(config, options, manifest, { manifestPath, archivePath });
  } catch (error) {
    if (error instanceof TransportError) {
      process.stderr.write(`transport failed: ${error.message}\n`);
      return 3;
    }
    throw error;
  } finally {
    fs.rmSync(stagingRoot, { recursive: true, force: true });
  }
}

async function execute(config, options, manifest, paths) {
  const host = ensureKnownHost(config);
  if (!host.ok) {
    process.stderr.write(
      `host key mismatch for ${config.transport.host}:${config.transport.port}\n` +
        `  expected ${config.transport.hostKeyFingerprint}\n  got      ${host.fingerprint ?? host.reason}\n`
    );
    return 3;
  }

  const runId = `${new Date().toISOString().replace(/[:.]/g, '-')}-${manifest.filesDigest.slice(0, 12)}`;
  const runDir = `${config.remote.runsDir}/${runId}`;

  const setup = runSsh(config, ['mkdir', '-p', runDir]);
  if (setup.status !== 0) {
    process.stderr.write(`could not create remote run directory: ${setup.stderr}\n`);
    return 3;
  }

  runScp(config, paths.archivePath, `${runDir}/snapshot.tar.gz`);
  runScp(config, paths.manifestPath, `${runDir}/manifest.json`);
  runScp(config, path.join(OPS_DIR, 'runner.sh'), `${runDir}/runner.sh`);

  process.stdout.write(`vps-rspec: run ${runId} on ${config.transport.host}:${config.transport.port}\n`);
  process.stdout.write(`vps-rspec: ${manifest.fileCount} files, archive ${manifest.archiveSha256.slice(0, 16)}...\n\n`);

  const result = await runSsh(
    config,
    ['bash', `${runDir}/runner.sh`, '--run-dir', runDir, '--', ...options.specs],
    { capture: false }
  );

  const receiptRaw = fetchRemoteFile(config, `${runDir}/receipt.json`);
  if (!receiptRaw) {
    process.stderr.write('\nvps-rspec: no receipt returned; treating as failure\n');
    return result.status === 0 ? 3 : result.status;
  }

  const receipt = JSON.parse(receiptRaw);
  if (options.json) process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
  else process.stdout.write(formatReceipt(receipt, runDir));

  // The receipt is evidence; the remote process exit status is the verdict.
  if (result.status !== 0) return result.status;
  if (receipt.exitCode !== 0) return receipt.exitCode;
  return 0;
}

function formatDryRun(summary) {
  const lines = [
    'vps-rspec --dry-run',
    `  head          ${summary.head}${summary.dirty ? ' (dirty working tree)' : ''}`,
    `  branch        ${summary.branch}`,
    `  files         ${summary.fileCount} (${summary.deletions} tracked deletions)`,
    `  files digest  ${summary.filesDigest}`,
    `  archive       ${summary.archiveSha256}`,
    `  runner        ${summary.runner.sha256}`,
    `  specs         ${summary.specs.join(' ')}`,
  ];
  if (summary.selected.length > 0) {
    lines.push(`  untracked included (${summary.selected.length}):`);
    for (const file of summary.selected.slice(0, 20)) lines.push(`    ${file}`);
    if (summary.selected.length > 20) lines.push(`    ... ${summary.selected.length - 20} more`);
  }
  return `${lines.join('\n')}\n`;
}

function formatReceipt(receipt, runDir) {
  return [
    '',
    'vps-rspec receipt',
    `  result        ${receipt.exitCode === 0 ? 'PASS' : 'FAIL'} (exit ${receipt.exitCode})`,
    `  stage         ${receipt.stage}`,
    `  examples      ${receipt.examples ?? 'n/a'} (${receipt.failures ?? 0} failed)`,
    `  image         ${receipt.image?.id ?? 'n/a'}`,
    `  ruby          ${receipt.runtime?.ruby ?? 'n/a'}`,
    `  deps key      ${receipt.keys?.dependency ?? 'n/a'}`,
    `  asset key     ${receipt.keys?.asset ?? 'n/a'}`,
    `  logs          ${runDir}`,
    '',
  ].join('\n');
}
