import 'dart:io';

import 'package:flutter_map/plugin_api.dart';
import 'package:ini/ini.dart';
import 'package:latlong2/latlong.dart';

import '../../regions/downloadable_region.dart';
import '../../regions/recovered_region.dart';

Future<RecoveredRegion?> read(File file) async {
  if (!await file.exists()) return null;

  final Config cfg = Config.fromStrings(await file.readAsLines());

  final RegionType type =
      RegionType.values.byName(cfg.get('type', 'regionType')!);

  final int minZoom = int.parse(cfg.get('zoom', 'minZoom')!);
  final int maxZoom = int.parse(cfg.get('zoom', 'maxZoom')!);

  final int start = int.parse(cfg.get('skip', 'start')!);
  final int? end = int.tryParse(cfg.get('skip', 'end')!);

  final int parallelThreads = int.parse(cfg.get('opts', 'parallelThreads')!);
  final bool preventRedownload = cfg.get('opts', 'preventRedownload') == 'true';
  final bool seaTileRemoval = cfg.get('opts', 'seaTileRemoval') == 'true';

  LatLngBounds? rectBounds;
  double? radius;
  LatLng? center;
  List<LatLng>? line;

  if (type == RegionType.rectangle) {
    rectBounds = LatLngBounds(
      LatLng(
        double.parse(cfg.get('area', 'nwLat')!),
        double.parse(cfg.get('area', 'nwLng')!),
      ),
      LatLng(
        double.parse(cfg.get('area', 'seLat')!),
        double.parse(cfg.get('area', 'seLng')!),
      ),
    );
  } else if (type == RegionType.circle) {
    radius = double.parse(cfg.get('area', 'radius')!);
    center = LatLng(
      double.parse(cfg.get('area', 'cLat')!),
      double.parse(cfg.get('area', 'cLng')!),
    );
  } else if (type == RegionType.line) {
    radius = double.parse(cfg.get('area', 'radius')!);

    line = [];
    for (int i = 0; i <= int.parse(cfg.get('area', 'length')!); i++) {
      line.add(LatLng(
        double.parse(cfg.get('area', i.toString() + 'Lat')!),
        double.parse(cfg.get('area', i.toString() + 'Lng')!),
      ));
    }
  }

  return RecoveredRegion.internal(
    type: type,
    bounds: rectBounds,
    center: center,
    line: line,
    radius: radius,
    minZoom: minZoom,
    maxZoom: maxZoom,
    start: start,
    end: end,
    parallelThreads: parallelThreads,
    preventRedownload: preventRedownload,
    seaTileRemoval: seaTileRemoval,
  );
}
