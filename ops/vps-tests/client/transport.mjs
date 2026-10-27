// SSH/scp transport for the maintained VPS backend test route (WOOT-32).
//
// Uses the standard OpenSSH client with strict host verification. Arguments are
// always passed as arrays, so spec selectors and paths are never spliced into a
// shell string. No bundled SSH binary, no protocol library, no bearer token.

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export class TransportError extends Error {}

export const MISSING_SSH_HINT =
  'The standard ssh/scp client is not installed in this Factory session.\n' +
  'This is the known platform prerequisite for WOOT-32, owned by Root with the\n' +
  'Mastra Factory platform lane (openssh-client, tracked in mastra-factory PR #10).\n' +
  'Do not install Ruby locally, run tests on a Mac, or invent an alternate transport.';

export function expandHome(value) {
  return value.startsWith('~/') ? path.join(os.homedir(), value.slice(2)) : value;
}

export function which(binary) {
  const result = spawnSync('sh', ['-c', `command -v ${binary}`], { encoding: 'utf8' });
  return result.status === 0 ? result.stdout.trim() : null;
}

export function knownHostsPath() {
  return path.join(os.homedir(), '.ssh', 'known_hosts');
}

/**
 * Pin the documented host key so the first connection is verified against the
 * repository's recorded fingerprint instead of blindly trusting the host.
 * StrictHostKeyChecking stays on; we never use `-o StrictHostKeyChecking=no`.
 */
export function sshBaseOptions(config) {
  const { transport } = config;
  return [
    '-p',
    String(transport.port),
    '-i',
    expandHome(transport.identityFile),
    '-o',
    `StrictHostKeyChecking=${transport.strictHostKeyChecking}`,
    '-o',
    `UserKnownHostsFile=${knownHostsPath()}`,
    '-o',
    `ConnectTimeout=${transport.connectTimeoutSeconds}`,
    '-o',
    'BatchMode=yes',
    '-o',
    `HostKeyAlgorithms=${transport.hostKeyAlgorithm}`,
  ];
}

export function target(config) {
  return `${config.transport.user}@${config.transport.host}`;
}

/** Read the host key fingerprint without trusting or storing it. */
export function scanHostFingerprint(config) {
  const keyscan = which('ssh-keyscan');
  if (!keyscan) return { ok: false, reason: 'ssh-keyscan unavailable' };
  const scan = spawnSync(
    keyscan,
    ['-p', String(config.transport.port), '-t', config.transport.hostKeyAlgorithm, config.transport.host],
    { encoding: 'utf8', timeout: 30000 }
  );
  if (scan.status !== 0 || !scan.stdout.trim()) {
    return { ok: false, reason: (scan.stderr || 'no key returned').trim() };
  }
  const keygen = which('ssh-keygen');
  if (!keygen) return { ok: false, reason: 'ssh-keygen unavailable' };
  const tmp = path.join(os.tmpdir(), `vps-hostkey-${process.pid}`);
  fs.writeFileSync(tmp, scan.stdout);
  try {
    const printed = spawnSync(keygen, ['-lf', tmp], { encoding: 'utf8' });
    const fingerprint = (printed.stdout || '').split(/\s+/).find(part => part.startsWith('SHA256:'));
    if (!fingerprint) return { ok: false, reason: 'could not parse fingerprint' };
    return {
      ok: fingerprint === config.transport.hostKeyFingerprint,
      fingerprint,
      expected: config.transport.hostKeyFingerprint,
    };
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}

export function ensureKnownHost(config) {
  const scanned = scanHostFingerprint(config);
  if (!scanned.ok) return scanned;

  const hostEntry = `[${config.transport.host}]:${config.transport.port}`;
  const knownHosts = knownHostsPath();
  const existing = fs.existsSync(knownHosts) ? fs.readFileSync(knownHosts, 'utf8') : '';
  if (existing.includes(hostEntry)) return { ...scanned, added: false };

  const keyscan = which('ssh-keyscan');
  const scan = spawnSync(
    keyscan,
    ['-p', String(config.transport.port), '-t', config.transport.hostKeyAlgorithm, config.transport.host],
    { encoding: 'utf8', timeout: 30000 }
  );
  fs.mkdirSync(path.dirname(knownHosts), { recursive: true });
  fs.appendFileSync(knownHosts, scan.stdout);
  return { ...scanned, added: true };
}

export function runSsh(config, remoteArgs, { capture = true } = {}) {
  const ssh = which('ssh');
  if (!ssh) throw new TransportError(MISSING_SSH_HINT);
  const args = [...sshBaseOptions(config), target(config), '--', ...remoteArgs];
  if (capture) {
    const result = spawnSync(ssh, args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
    return { status: result.status ?? 1, stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
  }
  return new Promise(resolve => {
    const child = spawn(ssh, args, { stdio: 'inherit' });
    // A signalled remote command must never look like success.
    child.on('close', (code, signal) => resolve({ status: signal ? 1 : code ?? 1, signal }));
  });
}

export function runScp(config, localPath, remotePath) {
  const scp = which('scp');
  if (!scp) throw new TransportError(MISSING_SSH_HINT);
  const { transport } = config;
  const args = [
    '-P',
    String(transport.port),
    '-i',
    expandHome(transport.identityFile),
    '-o',
    `StrictHostKeyChecking=${transport.strictHostKeyChecking}`,
    '-o',
    `UserKnownHostsFile=${knownHostsPath()}`,
    '-o',
    'BatchMode=yes',
    localPath,
    `${target(config)}:${remotePath}`,
  ];
  const result = spawnSync(scp, args, { encoding: 'utf8' });
  if (result.status !== 0) {
    throw new TransportError(`scp failed (${result.status}): ${(result.stderr || '').trim()}`);
  }
  return true;
}

export function fetchRemoteFile(config, remotePath) {
  const result = runSsh(config, ['cat', remotePath]);
  return result.status === 0 ? result.stdout : null;
}
