import 'dart:io';

class TorrentNetwork {
  const TorrentNetwork(this.name, this.address);

  final String name;
  final String address;
}

Future<List<TorrentNetwork>> listTorrentNetworks() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLinkLocal: false,
  );
  return [
    for (final interface in interfaces)
      for (final address in interface.addresses)
        if (!address.isLoopback)
          TorrentNetwork(interface.name, address.address),
  ];
}

Future<String?> resolveTorrentNetwork(
  String? selected, {
  Future<List<TorrentNetwork>> Function() list = listTorrentNetworks,
}) async {
  if (selected == null || selected.isEmpty) return null;
  final networks = await list();
  final candidates = networks.where((network) => network.name == selected);
  if (candidates.isEmpty) {
    throw StateError(
      'Сетевой интерфейс «$selected» недоступен. '
      'Подключите его или измените выбор в настройках Mumpa.',
    );
  }
  final address = InternetAddress.tryParse(candidates.first.address);
  if (address == null ||
      address.type != InternetAddressType.IPv4 ||
      address.isLoopback ||
      address.address == '0.0.0.0') {
    throw StateError('У выбранного интерфейса нет подходящего IPv4-адреса.');
  }
  return address.address;
}
