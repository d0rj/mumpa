import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export const upstreamHash = '309abd7c821546325ae6c509b40d969c5e39034be2314d21b3f5e0517feda7a7';
export const excludedFile = 'flaresolverr/_internal/chrome/interactive_ui_tests.exe';
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');

// Copy compressed entries verbatim. Only Chromium's standalone test runner is
// omitted; browser/runtime bytes, timestamps, attributes and CRCs stay intact.
export function runtimeArchive(input) {
  if (hash(input) !== upstreamHash) throw new Error('Unexpected FlareSolverr upstream archive');
  let end = input.length - 22;
  while (end >= input.length - 65557 && input.readUInt32LE(end) !== 0x06054b50) end--;
  if (end < input.length - 65557 || end + 22 + input.readUInt16LE(end + 20) !== input.length) {
    throw new Error('Invalid ZIP end record');
  }
  if (input.readUInt32LE(end + 4) !== 0 || input.readUInt16LE(end + 8) !== input.readUInt16LE(end + 10)) {
    throw new Error('Expected a single-disk ZIP');
  }
  const count = input.readUInt16LE(end + 10);
  const centralOffset = input.readUInt32LE(end + 16);
  const entries = [];
  let cursor = centralOffset;
  for (let i = 0; i < count; i++) {
    if (input.readUInt32LE(cursor) !== 0x02014b50) throw new Error('Invalid central record');
    const nameLength = input.readUInt16LE(cursor + 28);
    const length = 46 + nameLength + input.readUInt16LE(cursor + 30) + input.readUInt16LE(cursor + 32);
    entries.push({
      name: input.toString('utf8', cursor + 46, cursor + 46 + nameLength),
      offset: input.readUInt32LE(cursor + 42),
      central: input.subarray(cursor, cursor + length),
    });
    cursor += length;
  }
  if (cursor !== end || cursor - centralOffset !== input.readUInt32LE(end + 12)) {
    throw new Error('Unexpected ZIP directory layout');
  }
  entries.sort((a, b) => a.offset - b.offset);
  if (entries[0].offset !== 0 || entries.filter((entry) => entry.name === excludedFile).length !== 1) {
    throw new Error('Expected exactly one Chromium test runner');
  }
  const localParts = [], centralParts = [];
  let offset = 0;
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i];
    const next = entries[i + 1]?.offset ?? centralOffset;
    if (next <= entry.offset || input.readUInt32LE(entry.offset) !== 0x04034b50) {
      throw new Error('Invalid local ZIP record');
    }
    if (entry.name === excludedFile) continue;
    const bytes = input.subarray(entry.offset, next);
    const central = Buffer.from(entry.central);
    central.writeUInt32LE(offset, 42);
    localParts.push(bytes);
    centralParts.push(central);
    offset += bytes.length;
  }
  const directory = Buffer.concat(centralParts);
  const footer = Buffer.from(input.subarray(end));
  footer.writeUInt16LE(count - 1, 8);
  footer.writeUInt16LE(count - 1, 10);
  footer.writeUInt32LE(directory.length, 12);
  footer.writeUInt32LE(offset, 16);
  return Buffer.concat([...localParts, directory, footer]);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [source, destination] = process.argv.slice(2);
  if (!source || !destination || source === destination) throw new Error('Provide distinct source and destination paths');
  const input = readFileSync(source);
  const output = runtimeArchive(input);
  writeFileSync(destination, output);
  console.log(JSON.stringify({ upstreamBytes: input.length, runtimeBytes: output.length, sha256: hash(output) }));
}
