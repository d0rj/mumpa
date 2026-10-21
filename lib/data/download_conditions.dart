import 'package:flutter/services.dart';

class DownloadConditions {
  const DownloadConditions({required this.wifi, required this.charging});
  final bool wifi, charging;
  bool allows(Map<String, dynamic> settings) =>
      (settings['downloadsWifiOnly'] != true || wifi) &&
      (settings['downloadsChargingOnly'] != true || charging);
  static Future<DownloadConditions> read() async {
    final state = await const MethodChannel(
      'app.mumpa/device',
    ).invokeMapMethod<String, dynamic>('conditions');
    return DownloadConditions(
      wifi: state?['wifi'] == true,
      charging: state?['charging'] == true,
    );
  }
}
