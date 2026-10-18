import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { prepareRelease, publishRelease } from './ci/publish-release.mjs';

// Build first with tools/ci/build-release.ps1 -Local, then push the source.
// Keep gh credentials in memory; never print or write them to release files.
try {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim();
  if (git('status', '--porcelain', '--untracked-files=normal')) {
    throw new Error('Commit all source changes before publishing.');
  }
  const commit = git('rev-parse', 'HEAD');
  const version = /^version:\s*(\S+)/m.exec(readFileSync(resolve(root, 'pubspec.yaml'), 'utf8'))?.[1];
  if (!/^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?\+\d+$/.test(version ?? '')) {
    throw new Error('Invalid pubspec.yaml version');
  }
  const directory = resolve(root, `artifacts/release-${version.split('+')[0]}`);
  const plan = prepareRelease(directory, commit, undefined, { local: true });
  if (plan.version !== version) throw new Error('Build version does not match pubspec.yaml');
  const remote = git('remote', 'get-url', 'origin');
  const repository = /^(?:https:\/\/github\.com\/|git@github\.com:)([\w.-]+\/[\w.-]+?)(?:\.git)?$/.exec(remote)?.[1];
  if (!repository) throw new Error('Expected a github.com origin remote');
  // Do not publish a tag whose source has not reached the remote branch.
  const remoteHeads = git('ls-remote', 'origin', 'refs/heads/*');
  if (!remoteHeads.split('\n').some((line) => line.startsWith(`${commit}\t`))) {
    throw new Error('Push the build commit to origin before publishing.');
  }
  const token = process.env.GH_TOKEN || execFileSync('gh', ['auth', 'token'], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
  }).trim();
  const result = await publishRelease({ directory, repository, commit, token, expectedVersion: version, local: true });
  console.log(`${result.alreadyPublished ? 'Already published' : 'Published'}: ${result.url}`);
} catch (error) {
  // Subprocess errors may contain captured output, so omit their payload.
  console.error(error.status != null ? `Git/gh failed (exit ${error.status}); check local authentication.` : error.message);
  process.exitCode = 1;
}
