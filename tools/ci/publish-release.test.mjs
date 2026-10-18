import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { setImmediate as nextTurn } from 'node:timers/promises';
import { test } from 'node:test';

import { prepareRelease, publishRelease } from './publish-release.mjs';

const COMMIT = 'a'.repeat(40);
const OTHER_COMMIT = 'b'.repeat(40);
const RUN_ID = '123';
const VERSION = '1.2.7+15';
const TAG = 'v1.2.7';
const REPOSITORY = 'fixture-owner/mumpa';
const TOKEN = 'fixture-token-not-a-secret';
const RELEASE_URL = `https://github.com/${REPOSITORY}/releases/tag/${TAG}`;
const API_PATH = `/repos/${REPOSITORY}`;
const PACKAGE_PATHS = [
  'Mumpa-1.2.7-windows-x64.zip',
  'Mumpa-1.2.7-android-arm64.apk',
  'Mumpa-1.2.7-android-armv7.apk',
  'Mumpa-1.2.7-android-x86_64.apk',
  'Mumpa-1.2.7-android-symbols.zip',
  'sources/Mumpa-1.2.7-source.zip',
  'sources/TorrServer-MatriX.145.2-mumpa4-source.zip',
  'sources/TorrServer-MatriX.145.2-source.zip',
  'sources/Jackett-0.24.2806-source.zip',
  'sources/FlareSolverr-v3.5.2-source.zip',
];

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function jsonResponse(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

async function fixture(t, {
  stamp = 'current-build',
  commit = COMMIT,
  runId = RUN_ID,
} = {}) {
  const root = await mkdtemp(join(tmpdir(), 'mumpa-publish-test-'));
  const directory = join(root, 'artifacts');
  t.after(async () => {
    assert.equal(resolve(dirname(root)), resolve(tmpdir()));
    assert.ok(basename(root).startsWith('mumpa-publish-test-'));
    await rm(root, { recursive: true, force: true });
  });
  await mkdir(directory, { recursive: true });
  const manifest = [];
  for (const file of PACKAGE_PATHS) {
    // Deliberately tiny, original bytes: validation concerns hashes and sizes,
    // rather than interpreting ZIP/APK structures or downloading real media.
    const bytes = Buffer.from(`Original release fixture: ${stamp}: ${file}\n`);
    const path = join(directory, ...file.split('/'));
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, bytes);
    manifest.push({ file, bytes: bytes.length, sha256: sha256(bytes) });
  }
  const build = {
    version: VERSION,
    commit,
    engine: 'MatriX.145.2-mumpa4',
    githubRun: runId,
    androidSigning: 'ephemeral-debug-key',
  };
  await writeFile(join(directory, 'BUILD.json'), `${JSON.stringify(build, null, 2)}\n`);
  await writeFile(join(directory, 'SHA256.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  return { root, directory, manifest, build, commit, runId };
}

async function preparedBytes(prepared) {
  const result = new Map();
  for (const file of prepared.files) {
    result.set(file.name, file.data ?? await readFile(file.path));
  }
  return result;
}

async function bodyBytes(body) {
  if (body == null) return Buffer.alloc(0);
  if (typeof body === 'string') return Buffer.from(body);
  if (Buffer.isBuffer(body)) return body;
  if (body instanceof Uint8Array) return Buffer.from(body);
  if (typeof body.arrayBuffer === 'function') {
    return Buffer.from(await body.arrayBuffer());
  }
  if (typeof body[Symbol.asyncIterator] === 'function') {
    const chunks = [];
    for await (const chunk of body) chunks.push(Buffer.from(chunk));
    return Buffer.concat(chunks);
  }
  return Buffer.from(await new Response(body).arrayBuffer());
}

async function remoteRelease(oldFixture) {
  const prepared = prepareRelease(oldFixture.directory, oldFixture.commit, oldFixture.runId);
  const content = await preparedBytes(prepared);
  const bytesById = new Map();
  const assets = prepared.files.map((file, index) => {
    const id = 100 + index;
    const bytes = content.get(file.name);
    bytesById.set(id, bytes);
    return {
      id,
      name: file.name,
      state: 'uploaded',
      size: bytes.length,
      digest: `sha256:${sha256(bytes)}`,
    };
  });
  return {
    release: {
      id: 7,
      tag_name: TAG,
      draft: false,
      target_commitish: oldFixture.commit,
      html_url: RELEASE_URL,
      published_at: '2026-10-10T12:00:00Z',
      assets,
    },
    bytesById,
    content,
  };
}

function githubMock(expectedContent, {
  existing,
  tagCommit,
  refObject,
  tagObjects = new Map(),
  releasePages,
  lookupStatus = existing && !existing.release.draft ? 200 : 404,
  failUploadName,
  digestFailure,
} = {}) {
  const release = existing ? structuredClone(existing.release) : null;
  const verifiedAssets = (release?.assets ?? []).filter((asset) => {
    const bytes = expectedContent.get(asset.name);
    return bytes && asset.state === 'uploaded' && asset.size === bytes.length
      && asset.digest === `sha256:${sha256(bytes)}`;
  });
  const state = {
    calls: [],
    uploaded: new Map(verifiedAssets.map((asset) => [asset.name, asset])),
    uploadAttempts: [],
    deletedAssets: [],
    activeUploads: 0,
    peakUploads: 0,
    createCount: 0,
    publishCount: 0,
    listedPages: [],
    annotatedLookups: [],
    legacyCommitLookups: 0,
    remoteDownloads: [],
    release,
  };
  async function request(url, options = {}) {
    const address = new URL(url);
    const method = options.method ?? 'GET';
    const headers = new Headers(options.headers);
    state.calls.push({
      method, path: address.pathname, host: address.host,
      name: address.searchParams.get('name'),
    });
    assert.equal(headers.get('authorization'), `Bearer ${TOKEN}`);
    assert.ok(['api.github.com', 'uploads.github.com'].includes(address.host));

    if (method === 'GET' && address.pathname === `${API_PATH}/releases/tags/${TAG}`) {
      if (lookupStatus === 200) {
        assert.equal(state.release?.draft, false,
          'The release tag endpoint only returns published releases');
      }
      return lookupStatus === 200
        ? jsonResponse(state.release)
        : jsonResponse({ message: lookupStatus === 404 ? 'Not Found' : 'Forbidden' }, lookupStatus);
    }
    if (method === 'GET' && address.pathname === `${API_PATH}/releases`) {
      assert.equal(address.searchParams.get('per_page'), '100');
      const page = Number(address.searchParams.get('page'));
      assert.ok(Number.isSafeInteger(page) && page >= 1);
      state.listedPages.push(page);
      return jsonResponse(releasePages
        ? releasePages[page - 1] ?? []
        : page === 1 && state.release ? [state.release] : []);
    }
    if (method === 'GET' && address.pathname === `${API_PATH}/commits/${TAG}`) {
      state.legacyCommitLookups++;
      return jsonResponse({ message: 'No commit found for SHA: missing version tag' }, 422);
    }
    if (method === 'GET' && address.pathname === `${API_PATH}/git/ref/tags/${TAG}`) {
      const object = refObject ?? (tagCommit ? { type: 'commit', sha: tagCommit } : null);
      return object
        ? jsonResponse({ ref: `refs/tags/${TAG}`, object })
        : jsonResponse({ message: 'Not Found' }, 404);
    }
    if (method === 'GET' && address.pathname.startsWith(`${API_PATH}/git/tags/`)) {
      const sha = address.pathname.slice(`${API_PATH}/git/tags/`.length);
      assert.ok(tagObjects.has(sha), 'Only declared annotated tags may be read');
      state.annotatedLookups.push(sha);
      return jsonResponse({ sha, object: tagObjects.get(sha) });
    }
    const remoteId = address.pathname.match(/\/releases\/assets\/(\d+)$/)?.[1];
    if (method === 'GET' && remoteId) {
      assert.equal(headers.get('accept'), 'application/octet-stream');
      const id = Number(remoteId);
      assert.ok(existing?.bytesById.has(id), 'Only declared remote assets may be read');
      state.remoteDownloads.push(id);
      return new Response(existing.bytesById.get(id), {
        headers: { 'content-type': 'application/octet-stream' },
      });
    }
    if (method === 'DELETE' && remoteId) {
      assert.equal(state.release?.draft, true, 'Only draft assets may be replaced');
      const id = Number(remoteId);
      const asset = state.release.assets.find((entry) => entry.id === id);
      assert.ok(asset, 'Deletion must refer to an existing draft asset');
      state.deletedAssets.push(asset);
      state.uploaded.delete(asset.name);
      state.release.assets = state.release.assets.filter((entry) => entry.id !== id);
      return new Response(null, { status: 204 });
    }
    if (method === 'POST' && address.pathname === `${API_PATH}/releases`) {
      const body = JSON.parse((await bodyBytes(options.body)).toString('utf8'));
      assert.equal(body.tag_name, TAG);
      assert.equal(body.target_commitish, COMMIT);
      assert.equal(body.draft, true);
      state.createCount++;
      state.release = {
        id: 7,
        tag_name: TAG,
        draft: true,
        target_commitish: COMMIT,
        html_url: RELEASE_URL,
        upload_url: `https://uploads.github.com${API_PATH}/releases/7/assets{?name,label}`,
        assets: [],
      };
      return jsonResponse(state.release, 201);
    }
    if (method === 'POST' && address.pathname === `${API_PATH}/releases/7/assets`) {
      assert.equal(address.host, 'uploads.github.com');
      assert.equal(state.release?.draft, true);
      const name = address.searchParams.get('name');
      state.uploadAttempts.push(name);
      state.activeUploads++;
      state.peakUploads = Math.max(state.peakUploads, state.activeUploads);
      try {
        const bytes = await bodyBytes(options.body);
        await nextTurn();
        assert.ok(expectedContent.has(name), `Unexpected release asset ${name}`);
        assert.deepEqual(bytes, expectedContent.get(name));
        assert.equal(Number(headers.get('content-length')), bytes.length);
        if (typeof options.body?.[Symbol.asyncIterator] === 'function') {
          assert.equal(options.duplex, 'half');
        }
        if (name === failUploadName) {
          return jsonResponse({ message: 'Fixture upload failed' }, 500);
        }
        const asset = {
          id: 200 + state.uploaded.size,
          name,
          state: 'uploaded',
          size: bytes.length,
          digest: `sha256:${sha256(bytes)}`,
        };
        if (digestFailure === 'missing') delete asset.digest;
        if (digestFailure === 'wrong') asset.digest = `sha256:${'0'.repeat(64)}`;
        state.uploaded.set(name, asset);
        state.release.assets.push(asset);
        return jsonResponse(asset, 201);
      } finally {
        state.activeUploads--;
      }
    }
    if (method === 'PATCH' && address.pathname === `${API_PATH}/releases/7`) {
      assert.equal(state.uploaded.size, 12, 'The draft may publish only after all 12 verified uploads');
      assert.equal(state.activeUploads, 0);
      const body = JSON.parse((await bodyBytes(options.body)).toString('utf8'));
      assert.equal(body.draft, false);
      state.publishCount++;
      state.release.draft = false;
      return jsonResponse(state.release);
    }
    throw new Error(`Unexpected GitHub request: ${method} ${address.pathname}`);
  }
  return { request, state };
}

function publishOptions(current, request) {
  return {
    directory: current.directory,
    repository: REPOSITORY,
    commit: COMMIT,
    runId: RUN_ID,
    expectedVersion: VERSION,
    token: TOKEN,
    request,
  };
}

async function rejectedBeforeHttp(current, overrides = {}) {
  let requests = 0;
  await assert.rejects(publishRelease({
    ...publishOptions(current, async () => {
      requests++;
      throw new Error('Invalid local packages must never reach GitHub');
    }),
    ...overrides,
  }));
  assert.equal(requests, 0);
}

test('preflight validates all packages and emits a flat checksummed release manifest', async (t) => {
  const current = await fixture(t);
  const prepared = prepareRelease(current.directory, COMMIT, RUN_ID);
  assert.equal(prepared.version, VERSION);
  assert.equal(prepared.tag, TAG);
  assert.equal(typeof prepared.notes, 'string');
  assert.ok(prepared.notes.trim().length > 0);
  assert.equal(prepared.files.length, 12);
  assert.deepEqual(new Set(prepared.files.map((file) => file.name)),
    new Set([...PACKAGE_PATHS.map((file) => basename(file)), 'BUILD.json', 'SHA256.json']));
  const content = await preparedBytes(prepared);
  for (const file of prepared.files) {
    assert.equal(file.name, basename(file.name));
    const bytes = content.get(file.name);
    assert.equal(file.bytes, bytes.length);
    assert.equal(file.sha256, sha256(bytes));
  }
  const flattened = prepared.files.find((file) => file.name === 'SHA256.json');
  assert.ok(Buffer.isBuffer(flattened.data));
  const manifest = JSON.parse(flattened.data.toString('utf8'));
  assert.deepEqual(
    [...manifest].sort((a, b) => a.file.localeCompare(b.file)),
    current.manifest.map((entry) => ({
      ...entry,
      file: basename(entry.file),
    })).sort((a, b) => a.file.localeCompare(b.file)),
  );
  // Preparing publication never rewrites the original package manifest.
  assert.deepEqual(JSON.parse(await readFile(join(current.directory, 'SHA256.json'), 'utf8')),
    current.manifest);
});

test('local release uses explicit local provenance without a fabricated workflow run', async (t) => {
  const current = await fixture(t);
  current.build.buildSource = 'local';
  current.build.githubRun = null;
  current.build.androidSigning = 'local-debug-key';
  await writeFile(join(current.directory, 'BUILD.json'), JSON.stringify(current.build));
  const prepared = prepareRelease(current.directory, COMMIT, undefined, { local: true });
  assert.match(prepared.notes, /Локальная сборка/);
  assert.match(prepared.notes, /локальным debug-ключом/);
  assert.ok(prepared.notes.includes(`/commit/${COMMIT}`));
  assert.ok(!prepared.notes.includes('/actions/runs/'));
  assert.equal(prepared.files.length, 12);
  const mock = githubMock(await preparedBytes(prepared));
  const result = await publishRelease({ ...publishOptions(current, mock.request), local: true, runId: undefined });
  assert.equal(result.alreadyPublished, false);
  assert.equal(mock.state.uploaded.size, 12);
  assert.equal(mock.state.publishCount, 1);
});

test('local mode cannot bypass CI run provenance, or silently accept an Actions build', async (t) => {
  const current = await fixture(t);
  await rejectedBeforeHttp(current, { local: true, runId: undefined });
  current.build.buildSource = 'local';
  await writeFile(join(current.directory, 'BUILD.json'), JSON.stringify(current.build));
  await rejectedBeforeHttp(current, { local: true, runId: undefined });
  await rejectedBeforeHttp(current);
  current.build.githubRun = null;
  await writeFile(join(current.directory, 'BUILD.json'), JSON.stringify(current.build));
  await rejectedBeforeHttp(current, { local: true });
  await rejectedBeforeHttp(current, { local: true, runId: undefined, commit: OTHER_COMMIT });
  await rejectedBeforeHttp(current, { local: true, runId: undefined, expectedVersion: '1.2.8+16' });
});

test('local packages still require their original sizes and SHA256 before HTTP', async (t) => {
  const current = await fixture(t);
  current.build.buildSource = 'local';
  current.build.githubRun = null;
  await writeFile(join(current.directory, 'BUILD.json'), JSON.stringify(current.build));
  await writeFile(join(current.directory, PACKAGE_PATHS[1]), 'Corrupted local APK');
  await rejectedBeforeHttp(current, { local: true, runId: undefined });
});

test('corrupt package fails preflight before any HTTP', async (t) => {
  const current = await fixture(t);
  await writeFile(join(current.directory, PACKAGE_PATHS[0]), Buffer.from('Corrupted fixture'));
  assert.throws(() => prepareRelease(current.directory, COMMIT, RUN_ID));
  await rejectedBeforeHttp(current);
});

test('missing package fails preflight before any HTTP', async (t) => {
  const current = await fixture(t);
  await rm(join(current.directory, PACKAGE_PATHS[1]));
  assert.throws(() => prepareRelease(current.directory, COMMIT, RUN_ID));
  await rejectedBeforeHttp(current);
});

test('commit, run and version provenance mismatches cannot create a release', async (t) => {
  const current = await fixture(t);
  assert.throws(() => prepareRelease(current.directory, OTHER_COMMIT, RUN_ID));
  assert.throws(() => prepareRelease(current.directory, COMMIT, '456'));
  await rejectedBeforeHttp(current, { commit: OTHER_COMMIT });
  await rejectedBeforeHttp(current, { runId: '456' });
  await rejectedBeforeHttp(current, { expectedVersion: '1.2.8+16' });
});

test('manifest traversal is rejected even when the outside file has valid bytes', async (t) => {
  const current = await fixture(t);
  const entry = current.manifest[0];
  const bytes = await readFile(join(current.directory, entry.file));
  await writeFile(join(current.root, basename(entry.file)), bytes);
  entry.file = `../${basename(entry.file)}`;
  await writeFile(join(current.directory, 'SHA256.json'), JSON.stringify(current.manifest));
  assert.throws(() => prepareRelease(current.directory, COMMIT, RUN_ID));
  await rejectedBeforeHttp(current);
});

test('fresh release stays draft until 12 sequential verified uploads finish', async (t) => {
  const current = await fixture(t);
  const prepared = prepareRelease(current.directory, COMMIT, RUN_ID);
  const mock = githubMock(await preparedBytes(prepared));
  const result = await publishRelease(publishOptions(current, mock.request));
  assert.equal(result.tag, TAG);
  assert.equal(result.url, RELEASE_URL);
  assert.equal(result.alreadyPublished, false);
  assert.equal(mock.state.createCount, 1);
  assert.equal(mock.state.uploaded.size, 12);
  assert.equal(mock.state.peakUploads, 1);
  assert.equal(mock.state.publishCount, 1);
  assert.equal(mock.state.release.draft, false);
  assert.equal(mock.state.calls.at(-1).method, 'PATCH');
  for (const route of [
    `${API_PATH}/releases/tags/${TAG}`,
    `${API_PATH}/releases`,
    `${API_PATH}/git/ref/tags/${TAG}`,
  ]) {
    assert.ok(mock.state.calls.some((call) => call.method === 'GET' && call.path === route));
  }
  assert.deepEqual(mock.state.listedPages, [1]);
  assert.equal(mock.state.legacyCommitLookups, 0,
    'Fresh publication must avoid the legacy commits endpoint and its real 422');
});

test('Android debug symbols are required before any publication HTTP', async (t) => {
  const current = await fixture(t);
  const entry = current.manifest.find((item) => item.file.endsWith('-android-symbols.zip'));
  const bytes = await readFile(join(current.directory, entry.file));
  entry.file = 'unrelated.zip';
  await writeFile(join(current.directory, entry.file), bytes);
  await writeFile(join(current.directory, 'SHA256.json'), JSON.stringify(current.manifest));
  assert.throws(() => prepareRelease(current.directory, COMMIT, RUN_ID), /Missing package: .*android-symbols.zip/);
  await rejectedBeforeHttp(current);
});

test('upload failure aborts subsequent uploads and leaves the release draft', async (t) => {
  const current = await fixture(t);
  const prepared = prepareRelease(current.directory, COMMIT, RUN_ID);
  const failUploadName = prepared.files[3].name;
  const mock = githubMock(await preparedBytes(prepared), { failUploadName });
  await assert.rejects(publishRelease(publishOptions(current, mock.request)));
  assert.equal(mock.state.createCount, 1);
  assert.equal(mock.state.uploadAttempts.length, 4);
  assert.equal(mock.state.uploaded.size, 3);
  assert.equal(mock.state.publishCount, 0);
  assert.equal(mock.state.release.draft, true);
  assert.ok(mock.state.calls.every((call) => call.method !== 'PATCH'));
});

test('missing or incorrect upload digest cannot publish a successful HTTP response', async (t) => {
  for (const digestFailure of ['missing', 'wrong']) {
    await t.test(digestFailure, async (subtest) => {
      const current = await fixture(subtest);
      const prepared = prepareRelease(current.directory, COMMIT, RUN_ID);
      const mock = githubMock(await preparedBytes(prepared), { digestFailure });
      await assert.rejects(publishRelease(publishOptions(current, mock.request)));
      assert.equal(mock.state.uploadAttempts.length, 1);
      assert.equal(mock.state.publishCount, 0);
      assert.equal(mock.state.release.draft, true);
    });
  }
});

test('authorization 403 is not mistaken for a missing release', async (t) => {
  const current = await fixture(t);
  const prepared = prepareRelease(current.directory, COMMIT, RUN_ID);
  const mock = githubMock(await preparedBytes(prepared), { lookupStatus: 403 });
  await assert.rejects(publishRelease(publishOptions(current, mock.request)));
  assert.equal(mock.state.createCount, 0);
  assert.equal(mock.state.uploadAttempts.length, 0);
  assert.equal(mock.state.publishCount, 0);
  assert.ok(mock.state.calls.every((call) => call.method === 'GET'));
});

test('complete published release skips a same-commit rebuild using remote manifests', async (t) => {
  const current = await fixture(t);
  const old = await fixture(t, { stamp: 'previous-timestamp-and-signature', runId: '122' });
  const existing = await remoteRelease(old);
  const prepared = prepareRelease(current.directory, COMMIT, RUN_ID);
  const currentContent = await preparedBytes(prepared);
  assert.notEqual(sha256(currentContent.get(PACKAGE_PATHS[0])),
    sha256(existing.content.get(PACKAGE_PATHS[0])));
  const mock = githubMock(currentContent, { existing, tagCommit: COMMIT });
  const result = await publishRelease(publishOptions(current, mock.request));
  assert.equal(result.tag, TAG);
  assert.equal(result.url, RELEASE_URL);
  assert.equal(result.alreadyPublished, true);
  assert.equal(mock.state.createCount, 0);
  assert.equal(mock.state.uploadAttempts.length, 0);
  assert.equal(mock.state.publishCount, 0);
  assert.equal(mock.state.remoteDownloads.length, 2);
  const downloadedNames = mock.state.remoteDownloads.map((id) =>
    existing.release.assets.find((asset) => asset.id === id).name);
  assert.deepEqual(new Set(downloadedNames), new Set(['BUILD.json', 'SHA256.json']));
  assert.ok(mock.state.calls.every((call) => call.method === 'GET'));
});

test('published tag targeting another commit cannot be silently reused', async (t) => {
  const current = await fixture(t);
  const old = await fixture(t, { commit: OTHER_COMMIT });
  const existing = await remoteRelease(old);
  const prepared = prepareRelease(current.directory, COMMIT, RUN_ID);
  const mock = githubMock(await preparedBytes(prepared), {
    existing,
    tagCommit: OTHER_COMMIT,
  });
  await assert.rejects(publishRelease(publishOptions(current, mock.request)));
  assert.equal(mock.state.createCount, 0);
  assert.equal(mock.state.uploadAttempts.length, 0);
  assert.equal(mock.state.publishCount, 0);
  assert.ok(mock.state.calls.every((call) => call.method === 'GET'));
});

test('same-commit partial draft skips valid assets and replaces a bad asset before publishing', async (t) => {
  for (const defect of ['starter', 'wrong-digest']) {
    await t.test(defect, async (subtest) => {
      const current = await fixture(subtest);
      const prepared = prepareRelease(current.directory, COMMIT, RUN_ID);
      const content = await preparedBytes(prepared);
      const existing = await remoteRelease(current);
      existing.release.draft = true;
      delete existing.release.published_at;
      existing.release.assets = existing.release.assets.slice(0, 3);
      const validNames = existing.release.assets.slice(0, 2).map((asset) => asset.name);
      const bad = existing.release.assets[2];
      if (defect === 'starter') bad.state = 'starter';
      else bad.digest = `sha256:${'0'.repeat(64)}`;
      const mock = githubMock(content, { existing, tagCommit: COMMIT });

      const result = await publishRelease(publishOptions(current, mock.request));
      assert.equal(result.alreadyPublished, false);
      assert.equal(result.url, RELEASE_URL);
      assert.equal(mock.state.createCount, 0, 'Resume must reuse the existing draft');
      assert.deepEqual(mock.state.listedPages, [1],
        'A draft must be discovered through the release list after tag lookup 404');
      assert.equal(mock.state.uploadAttempts.length, 10);
      assert.ok(validNames.every((name) => !mock.state.uploadAttempts.includes(name)));
      assert.deepEqual(new Set(mock.state.uploadAttempts),
        new Set(prepared.files.slice(2).map((file) => file.name)));
      assert.deepEqual(mock.state.deletedAssets.map((asset) => asset.id), [bad.id]);
      const deletedAt = mock.state.calls.findIndex((call) =>
        call.method === 'DELETE' && call.path === `${API_PATH}/releases/assets/${bad.id}`);
      const uploadedAt = mock.state.calls.findIndex((call) =>
        call.method === 'POST' && call.name === bad.name);
      assert.ok(deletedAt >= 0 && uploadedAt > deletedAt,
        'The invalid draft asset must be removed before reupload');
      assert.equal(mock.state.uploaded.size, 12);
      assert.equal(mock.state.release.assets.length, 12);
      assert.equal(mock.state.peakUploads, 1);
      assert.equal(mock.state.publishCount, 1);
      assert.equal(mock.state.calls.at(-1).method, 'PATCH');
      assert.equal(mock.state.release.draft, false);
      for (const [name, bytes] of content) {
        const asset = mock.state.uploaded.get(name);
        assert.equal(asset.state, 'uploaded');
        assert.equal(asset.size, bytes.length);
        assert.equal(asset.digest, `sha256:${sha256(bytes)}`);
      }
    });
  }
});

test('foreign draft and invalid published assets fail without any remote writes', async (t) => {
  for (const defect of [
    'draft-other-commit',
    'published-missing-package',
    'published-package-digest',
    'published-metadata-digest',
  ]) {
    await t.test(defect, async (subtest) => {
      const current = await fixture(subtest);
      const prepared = prepareRelease(current.directory, COMMIT, RUN_ID);
      const existing = await remoteRelease(current);
      if (defect === 'draft-other-commit') {
        existing.release.draft = true;
        existing.release.target_commitish = OTHER_COMMIT;
      } else if (defect === 'published-missing-package') {
        existing.release.assets = existing.release.assets.filter((asset) =>
          asset.name !== basename(PACKAGE_PATHS[0]));
      } else {
        const name = defect === 'published-metadata-digest'
          ? 'BUILD.json' : basename(PACKAGE_PATHS[0]);
        existing.release.assets.find((asset) => asset.name === name).digest =
          `sha256:${'0'.repeat(64)}`;
      }
      // The tag is correct even in the foreign-draft case; reject that draft's
      // target itself, rather than relying on the earlier tag mismatch guard.
      const mock = githubMock(await preparedBytes(prepared), {
        existing,
        tagCommit: COMMIT,
      });
      await assert.rejects(publishRelease(publishOptions(current, mock.request)));
      assert.equal(mock.state.createCount, 0);
      assert.equal(mock.state.uploadAttempts.length, 0);
      assert.equal(mock.state.deletedAssets.length, 0);
      assert.equal(mock.state.publishCount, 0);
      assert.ok(mock.state.calls.every((call) => call.method === 'GET'));
    });
  }
});

test('draft on release-list page two is resumed after a full first page', async (t) => {
  const current = await fixture(t);
  const prepared = prepareRelease(current.directory, COMMIT, RUN_ID);
  const existing = await remoteRelease(current);
  existing.release.draft = true;
  const firstPage = Array.from({ length: 100 }, (_, index) => ({
    id: 1000 + index,
    tag_name: index === 0 ? `${TAG}0` : `v0.0.${index}`,
    draft: index % 2 === 0,
    target_commitish: COMMIT,
    assets: [],
  }));
  const mock = githubMock(await preparedBytes(prepared), {
    existing,
    tagCommit: COMMIT,
    releasePages: [firstPage, [existing.release]],
  });
  const result = await publishRelease(publishOptions(current, mock.request));
  assert.equal(result.alreadyPublished, false);
  assert.deepEqual(mock.state.listedPages, [1, 2]);
  assert.equal(mock.state.createCount, 0);
  assert.equal(mock.state.uploadAttempts.length, 0,
    'All assets on the discovered draft already match this build');
  assert.equal(mock.state.publishCount, 1);
  assert.equal(mock.state.release.draft, false);
  assert.equal(mock.state.legacyCommitLookups, 0);
});

test('matching drafts across release-list pages are ambiguous and never mutated', async (t) => {
  const current = await fixture(t);
  const prepared = prepareRelease(current.directory, COMMIT, RUN_ID);
  const existing = await remoteRelease(current);
  existing.release.draft = true;
  const firstPage = Array.from({ length: 100 }, (_, index) => index === 0
    ? existing.release
    : { id: 1000 + index, tag_name: `v0.0.${index}`, draft: true, assets: [] });
  const secondDraft = { ...existing.release, id: 8 };
  const mock = githubMock(await preparedBytes(prepared), {
    existing,
    tagCommit: COMMIT,
    releasePages: [firstPage, [secondDraft]],
  });
  await assert.rejects(publishRelease(publishOptions(current, mock.request)),
    /Multiple releases have this version tag/);
  assert.deepEqual(mock.state.listedPages, [1, 2]);
  assert.equal(mock.state.createCount, 0);
  assert.equal(mock.state.uploadAttempts.length, 0);
  assert.equal(mock.state.deletedAssets.length, 0);
  assert.equal(mock.state.publishCount, 0);
  assert.ok(mock.state.calls.every((call) => call.method === 'GET'));
});

test('nested annotated version tag resolves to the same commit before publication', async (t) => {
  const current = await fixture(t);
  const prepared = prepareRelease(current.directory, COMMIT, RUN_ID);
  const firstTag = 'c'.repeat(40);
  const secondTag = 'd'.repeat(40);
  const mock = githubMock(await preparedBytes(prepared), {
    refObject: { type: 'tag', sha: firstTag },
    tagObjects: new Map([
      [firstTag, { type: 'tag', sha: secondTag }],
      [secondTag, { type: 'commit', sha: COMMIT }],
    ]),
  });
  const result = await publishRelease(publishOptions(current, mock.request));
  assert.equal(result.alreadyPublished, false);
  assert.deepEqual(mock.state.annotatedLookups, [firstTag, secondTag]);
  assert.equal(mock.state.legacyCommitLookups, 0);
  assert.equal(mock.state.uploaded.size, 12);
  assert.equal(mock.state.publishCount, 1);
});

test('annotated tag mismatch or cycle is rejected before remote writes', async (t) => {
  for (const defect of ['other-commit', 'cycle']) {
    await t.test(defect, async (subtest) => {
      const current = await fixture(subtest);
      const prepared = prepareRelease(current.directory, COMMIT, RUN_ID);
      const firstTag = 'c'.repeat(40);
      const secondTag = 'd'.repeat(40);
      const mock = githubMock(await preparedBytes(prepared), {
        refObject: { type: 'tag', sha: firstTag },
        tagObjects: new Map([
          [firstTag, { type: 'tag', sha: secondTag }],
          [secondTag, defect === 'cycle'
            ? { type: 'tag', sha: firstTag }
            : { type: 'commit', sha: OTHER_COMMIT }],
        ]),
      });
      await assert.rejects(publishRelease(publishOptions(current, mock.request)),
        defect === 'cycle' ? /does not resolve to a commit/ : /another commit/);
      assert.deepEqual(mock.state.annotatedLookups, [firstTag, secondTag]);
      assert.equal(mock.state.legacyCommitLookups, 0);
      assert.equal(mock.state.createCount, 0);
      assert.equal(mock.state.uploadAttempts.length, 0);
      assert.equal(mock.state.deletedAssets.length, 0);
      assert.equal(mock.state.publishCount, 0);
      assert.ok(mock.state.calls.every((call) => call.method === 'GET'));
    });
  }
});
