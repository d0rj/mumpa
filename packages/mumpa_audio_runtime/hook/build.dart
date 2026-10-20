import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

// Audio-only mpv 0.41 with the required FFmpeg DSP filters. These SHA-256
// pins are from mpv_audio_kit 0.5.1's libmpv-r17 manifest/build hook.
const release = 'libmpv-r17';
const hashes = {
  'libmpv_windows-x86_64.dll':
      '4f4d785e85a0fced6f15bd3a29c013f3558933869fd129a94937b3d40401349c',
  'libmpv_windows-arm64.dll':
      '17641c30a02b2f3eafa542d90ffa9f2a28f1d0d298893b0f2cc0fa30c755ffa8',
  'libmpv_android-arm64-v8a.so':
      '34cde4b362d19af93e83e86358ae37c9939f39a6d8ae69e871f686d1d40953d9',
  'libmpv_android-armeabi-v7a.so':
      '1eaa0d500137aa63a6b32a4696968909e110b4285be816e4c1deeb2c495b44be',
  'libmpv_android-x86_64.so':
      '3a22caa584908780ba6eb3f6984e29c824c256e87c8c58e469fb031642f83c53',
  'libmpv_linux-x86_64.so':
      'e23bae27d1b39f89c60fceda34aae50e8e9cf87c9b586ad3b1563c036db3bc9c',
  'libmpv_linux-aarch64.so':
      '0408e3283bcb574071f2d209567fcef919a672dba7b845edd3422b567f0aaea5',
};

Future<bool> matches(File file, String hash) async =>
    await file.exists() &&
    (await sha256.bind(file.openRead()).first).toString() == hash;

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final arch = code.targetArchitecture;
    final asset = switch (code.targetOS) {
      OS.windows =>
        'libmpv_windows-${arch == Architecture.arm64 ? 'arm64' : 'x86_64'}.dll',
      OS.android =>
        'libmpv_android-${switch (arch) {
          Architecture.arm => 'armeabi-v7a',
          Architecture.arm64 => 'arm64-v8a',
          Architecture.x64 => 'x86_64',
          _ => throw UnsupportedError('Android ABI $arch'),
        }}.so',
      OS.linux =>
        'libmpv_linux-${arch == Architecture.arm64 ? 'aarch64' : 'x86_64'}.so',
      _ => throw UnsupportedError('Mumpa audio runtime: ${code.targetOS}'),
    };
    final expected = hashes[asset]!;
    final cached = File.fromUri(input.outputDirectoryShared.resolve(asset));
    await cached.parent.create(recursive: true);
    if (!await matches(cached, expected)) {
      final part = File('${cached.path}.download');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 30);
      try {
        final request = await client.getUrl(
          Uri.parse(
            'https://github.com/ales-drnz/mpv_audio_kit/releases/download/$release/$asset',
          ),
        );
        final response = await request.close();
        if (response.statusCode != 200) {
          throw HttpException(
            'Audio runtime download: HTTP ${response.statusCode}',
          );
        }
        await response
            .timeout(const Duration(seconds: 60))
            .pipe(part.openWrite());
        if (!await matches(part, expected)) {
          throw StateError('Audio runtime SHA-256 mismatch: $asset');
        }
        if (await cached.exists()) await cached.delete();
        await part.rename(cached.path);
      } finally {
        client.close(force: true);
        if (await part.exists()) await part.delete();
      }
    }
    final fileName = code.targetOS == OS.windows
        ? 'mpv_audio_kit.dll'
        : 'libmpv_audio_kit.so';
    final bundled = await cached.copy(
      File.fromUri(input.outputDirectory.resolve(fileName)).path,
    );
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'libmpv',
        linkMode: DynamicLoadingBundled(),
        file: bundled.uri,
      ),
    );
  });
}
