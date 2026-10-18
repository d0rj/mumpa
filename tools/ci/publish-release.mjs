import { createHash } from 'node:crypto';
import { createReadStream, readFileSync, realpathSync, statSync } from 'node:fs';
import { basename, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';

const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');
const parseJson = (bytes) => JSON.parse(bytes.toString().replace(/^\uFEFF/, ''));
const androidCertificate = readFileSync(new URL('../../android/release-signing.sha256', import.meta.url), 'utf8').trim();

export function prepareRelease(directory, expectedCommit, expectedRunId, { local = false } = {}) {
  if (!/^[a-f0-9]{40}$/.test(expectedCommit ?? '')) throw new Error('Invalid source commit');
  if (local ? expectedRunId != null : !/^\d+$/.test(String(expectedRunId ?? ''))) {
    throw new Error('Invalid workflow run ID');
  }
  const root = realpathSync(directory);
  const buildData = readFileSync(resolve(root, 'BUILD.json'));
  const build = parseJson(buildData);
  const match = /^(\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?)\+(\d+)$/.exec(build.version ?? '');
  if (!match) throw new Error('Expected version+build in BUILD.json');
  if (build.commit !== expectedCommit || (local
    ? build.buildSource !== 'local' || build.githubRun != null
    : build.buildSource === 'local' || String(build.githubRun) !== String(expectedRunId))) {
    throw new Error('Build commit or workflow run does not match this release');
  }
  if (!/^[A-Za-z0-9._-]+$/.test(build.engine ?? '')) throw new Error('Invalid engine version');
  if (build.androidSigning !== 'release-keystore' || !/^[a-f0-9]{64}$/.test(androidCertificate) ||
      build.androidCertificateSha256 !== androidCertificate) {
    throw new Error('Build must use the pinned persistent Android signing certificate');
  }
  const version = match[1];
  const required = [
    `Mumpa-${version}-windows-x64.zip`,
    ...['arm64', 'armv7', 'x86_64'].map((abi) => `Mumpa-${version}-android-${abi}.apk`),
    `Mumpa-${version}-android-symbols.zip`,
    `sources/Mumpa-${version}-source.zip`,
    `sources/TorrServer-${build.engine}-source.zip`,
    `sources/TorrServer-${build.engine.replace(/-mumpa\d+$/, '')}-source.zip`,
  ];
  const manifest = parseJson(readFileSync(resolve(root, 'SHA256.json')));
  if (!Array.isArray(manifest) || manifest.length !== 10) throw new Error('Expected ten packages in SHA256 manifest');
  const seen = new Set();
  const files = manifest.map((entry) => {
    if (typeof entry.file !== 'string' ||
        !/^(?:[A-Za-z0-9._-]+\.(?:zip|apk)|sources\/[A-Za-z0-9._-]+-source\.zip)$/.test(entry.file)) {
      throw new Error('Invalid package path in SHA256 manifest');
    }
    const name = basename(entry.file);
    if (seen.has(name)) throw new Error(`Duplicate package name: ${name}`);
    seen.add(name);
    const path = realpathSync(resolve(root, entry.file));
    const size = statSync(path);
    if (!path.startsWith(root + sep) || !size.isFile()) throw new Error('Package leaves release directory');
    if (!Number.isSafeInteger(entry.bytes) || entry.bytes <= 0 || size.size !== entry.bytes ||
        !/^[a-f0-9]{64}$/.test(entry.sha256 ?? '') || digest(readFileSync(path)) !== entry.sha256) {
      throw new Error(`Package size/SHA256 mismatch: ${name}`);
    }
    return { name, path, bytes: entry.bytes, sha256: entry.sha256 };
  });
  for (const file of required) {
    if (!manifest.some((entry) => entry.file === file)) throw new Error(`Missing package: ${file}`);
  }
  for (const helper of ['Jackett', 'FlareSolverr']) {
    if (!manifest.some((entry) => entry.file.startsWith(`sources/${helper}-`))) {
      throw new Error(`Missing ${helper} sources`);
    }
  }
  if (manifest.filter((entry) => entry.file.startsWith('sources/TorrServer-')).length < 2) {
    throw new Error('Missing upstream TorrServer sources');
  }
  // Release assets have flat names, unlike the directory layout in Actions.
  const sums = Buffer.from(JSON.stringify(files.map((file) => ({
    file: file.name, bytes: file.bytes, sha256: file.sha256,
  })), null, 2) + '\n');
  for (const [name, data] of [['BUILD.json', buildData], ['SHA256.json', sums]]) {
    files.push({ name, data, bytes: data.length, sha256: digest(data) });
  }
  const signing = 'APK подписаны постоянным ключом релиза, совместимым с локальным выпуском v1.2.22.';
  const provenance = local
    ? `Локальная сборка Windows и Android, без GitHub Actions. [Исходный commit](https://github.com/REPOSITORY/commit/${build.commit}).`
    : `Commit: \`${build.commit}\`. [Проверки и сборка](https://github.com/REPOSITORY/actions/runs/${build.githubRun}).`;
  return {
    version: build.version, tag: `v${version}`, files, prerelease: version.includes('-'),
    notes: `Mumpa **${build.version}**\n\n` +
      `Windows: распакуйте Mumpa-${version}-windows-x64.zip и откройте Mumpa/Install Mumpa.cmd для установки в меню «Пуск». Переносной запуск: Mumpa/mumpa.exe.\n\n` +
      `Android: Mumpa-${version}-android-arm64.apk для большинства телефонов; также доступны ARMv7 и x86_64. ${signing}\n\n` +
      `Исходники приложения и помощников приложены. SHA256.json использует имена файлов этой страницы.\n\n` +
      `${provenance}\n`,
  };
}

export async function publishRelease({ directory, repository, commit, runId, token, expectedVersion, local = false, request = fetch }) {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository ?? '')) throw new Error('Invalid repository');
  if (!token) throw new Error('GH_TOKEN is required');
  const plan = prepareRelease(directory, commit, runId, { local });
  if (expectedVersion && plan.version !== expectedVersion) throw new Error('Build version does not match this release');
  const api = `https://api.github.com/repos/${repository}`;
  const headers = {
    authorization: `Bearer ${token}`, accept: 'application/vnd.github+json',
    'x-github-api-version': '2026-03-10', 'user-agent': 'Mumpa-release-publisher',
  };
  async function call(url, { method = 'GET', json, body, contentType, bytes, binary = false, optional = false } = {}) {
    const options = {
      method, headers: { ...headers }, signal: AbortSignal.timeout(30 * 60 * 1000),
    };
    if (binary) options.headers.accept = 'application/octet-stream';
    if (json !== undefined) {
      options.headers['content-type'] = 'application/json';
      options.body = JSON.stringify(json);
    } else if (body !== undefined) {
      options.headers['content-type'] = contentType;
      options.headers['content-length'] = String(bytes);
      options.body = body;
      options.duplex = 'half';
    }
    const response = await request(url, options);
    if (optional && response.status === 404) return null;
    if (!response.ok) throw new Error(`GitHub ${method} failed: HTTP ${response.status} ${(await response.text()).slice(0, 500)}`);
    if (response.status === 204) return null;
    return binary ? Buffer.from(await response.arrayBuffer()) : response.json();
  }
  const tagPath = encodeURIComponent(plan.tag);
  let release = await call(`${api}/releases/tags/${tagPath}`, { optional: true });
  // The tag endpoint only finds published releases. Drafts need the list API,
  // which includes them for this contents:write token.
  if (!release) {
    const matching = [];
    for (let page = 1; ; page++) {
      const releases = await call(`${api}/releases?per_page=100&page=${page}`);
      if (!Array.isArray(releases)) throw new Error('Invalid GitHub release list');
      matching.push(...releases.filter((item) => item.tag_name === plan.tag));
      if (matching.length > 1) throw new Error('Multiple releases have this version tag');
      if (releases.length < 100) break;
    }
    release = matching[0] ?? null;
  }
  // /commits/{missing-tag} returns 422; an exact Git ref lookup returns 404.
  // Peel annotated tags so both tag formats bind to the actual build commit.
  const ref = await call(`${api}/git/ref/tags/${tagPath}`, { optional: true });
  if (ref && !ref.object) throw new Error('Invalid version tag reference');
  let remoteTag = ref?.object ?? null;
  const visited = new Set();
  while (remoteTag) {
    if (!/^[a-f0-9]{40}$/.test(remoteTag.sha ?? '')) throw new Error('Invalid version tag object');
    if (remoteTag.type === 'commit') break;
    if (remoteTag.type !== 'tag' || visited.has(remoteTag.sha) || visited.size >= 32) {
      throw new Error('Version tag does not resolve to a commit');
    }
    visited.add(remoteTag.sha);
    const tag = await call(`${api}/git/tags/${remoteTag.sha}`);
    remoteTag = tag.object;
    if (!remoteTag) throw new Error('Invalid annotated version tag');
  }
  if (remoteTag && remoteTag.sha !== commit) throw new Error('Version tag belongs to another commit; bump pubspec.yaml version');
  if (release && !release.draft) {
    if (!remoteTag) throw new Error('Published release has no matching version tag');
    const assets = new Map(release.assets.map((asset) => [asset.name, asset]));
    async function metadata(name) {
      const asset = assets.get(name);
      if (!asset) throw new Error(`Published release is incomplete: ${name}`);
      const data = await call(`${api}/releases/assets/${asset.id}`, { binary: true });
      verifyAsset(asset, { name, bytes: data.length, sha256: digest(data) });
      return parseJson(data);
    }
    const build = await metadata('BUILD.json');
    if (build.commit !== commit || build.version !== plan.version) throw new Error('Published build metadata does not match');
    const sums = await metadata('SHA256.json');
    const expected = plan.files.filter((file) => file.path).map((file) => file.name);
    if (!Array.isArray(sums) || sums.length !== expected.length ||
        new Set(sums.map((entry) => entry.file)).size !== sums.length) throw new Error('Published manifest is incomplete');
    for (const file of sums) {
      if (!expected.includes(file.file) || !Number.isSafeInteger(file.bytes) || file.bytes <= 0 ||
          !/^[a-f0-9]{64}$/.test(file.sha256 ?? '')) throw new Error('Invalid published manifest entry');
      verifyAsset(assets.get(file.file), { name: file.file, bytes: file.bytes, sha256: file.sha256 });
    }
    return { tag: plan.tag, url: release.html_url, alreadyPublished: true };
  }
  if (release && release.target_commitish !== commit) throw new Error('Draft belongs to another commit; bump pubspec.yaml version');
  if (!release) release = await call(`${api}/releases`, { method: 'POST', json: {
    tag_name: plan.tag, target_commitish: commit, name: `Mumpa ${plan.version}`,
    body: plan.notes.replace('REPOSITORY', repository), draft: true, prerelease: plan.prerelease,
  } });
  // Recover a partial draft without modifying an already published version.
  const assets = new Map((release.assets ?? []).map((asset) => [asset.name, asset]));
  for (const file of plan.files) {
    const previous = assets.get(file.name);
    if (previous?.state === 'uploaded' && previous.size === file.bytes && previous.digest === `sha256:${file.sha256}`) continue;
    if (previous) await call(`${api}/releases/assets/${previous.id}`, { method: 'DELETE' });
    const stream = file.data ?? createReadStream(file.path);
    try {
      const asset = await call(`https://uploads.github.com/repos/${repository}/releases/${release.id}/assets?name=${encodeURIComponent(file.name)}`, {
        method: 'POST', body: stream, bytes: file.bytes,
        contentType: file.name.endsWith('.apk') ? 'application/vnd.android.package-archive'
          : file.name.endsWith('.zip') ? 'application/zip' : 'application/json',
      });
      verifyAsset(asset, file);
    } finally {
      if (!file.data) stream.destroy();
    }
  }
  release = await call(`${api}/releases/${release.id}`, { method: 'PATCH', json: {
    draft: false, make_latest: plan.prerelease ? 'false' : 'legacy',
    name: `Mumpa ${plan.version}`, body: plan.notes.replace('REPOSITORY', repository),
    prerelease: plan.prerelease,
  } });
  if (release.draft) throw new Error('GitHub kept the release as a draft');
  return { tag: plan.tag, url: release.html_url, alreadyPublished: false };
}

function verifyAsset(asset, file) {
  if (!asset || asset.name !== file.name || asset.state !== 'uploaded' ||
      asset.size !== file.bytes || asset.digest !== `sha256:${file.sha256}`) {
    throw new Error(`Uploaded asset size/SHA256 mismatch or incomplete asset: ${file.name}`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const result = await publishRelease({
      directory: process.env.RELEASE_DIRECTORY ?? 'artifacts/ci-release',
      repository: process.env.GITHUB_REPOSITORY, commit: process.env.RELEASE_COMMIT,
      runId: process.env.GITHUB_RUN_ID, token: process.env.GH_TOKEN,
      expectedVersion: process.env.RELEASE_VERSION,
    });
    console.log(`${result.alreadyPublished ? 'Already published' : 'Published'}: ${result.url}`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
