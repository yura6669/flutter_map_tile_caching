import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:background_fetch/background_fetch.dart';
import 'package:battery_info/battery_info_plugin.dart';
import 'package:battery_info/enums/charging_status.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_map/plugin_api.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p show joinAll;
import 'package:permission_handler/permission_handler.dart';
import 'package:queue/queue.dart';

import 'bulkDownload/downloadProgress.dart';
import 'bulkDownload/downloader.dart';
import 'bulkDownload/tileLoops.dart';
import 'internal/imageProvider.dart';
import 'internal/privateMisc.dart';
import 'regions/downloadableRegion.dart';
import 'regions/recoveredRegion.dart';
import 'storageManager.dart';

/// Multiple behaviors dictating how caching should be carried out, if at all
enum CacheBehavior {
  /// Only get tiles from the local cache
  ///
  /// Useful for applications with dedicated 'Offline Mode'.
  cacheOnly,

  /// Get tiles from the local cache, going on the Internet to update the cached tile if it has expired (`cachedValidDuration` has passed)
  cacheFirst,

  /// Get tiles from the Internet and update the cache for every tile
  onlineFirst,
}

/// A `TileProvider` to automatically cache browsed (panned over) tiles to a local caching database. Also contains methods to download regions of a map to a local caching database using an instance.
///
/// Requires a valid cache directory: [parentDirectory]. [storeName] defaults to the default store, 'mainStore', but can be overriden to different stores. On initialisation, automatically creates the cache store if it does not exist.
///
/// Optionally adjust:
///  - [maxStoreLength] - the number of tiles that can be stored at once in this cache store
///  - [behavior] - the caching behavior to use, affecting [cachedValidDuration].
///  - [cachedValidDuration] -  the length of time a cached tile is valid before needing to be updated in some caching behaviors
///
/// See each property's individual documentation for more detail.
class StorageCachingTileProvider extends TileProvider {
  /// Deprecated. Migrate to `maxStoreLength`. Will be removed in the next release.
  @Deprecated(
      'Migrate to `maxStoreLength`. Will be removed in the next release.')
  static final kMaxPreloadTileAreaCount = 20000;

  /// The directory to place cache stores into
  ///
  /// Use [MapCachingManager.normalCache] wherever possible, or [MapCachingManager.temporaryCache] alternatively (see documentation). To use those `Future` values here, you will need to wrap your [FlutterMap] widget in a [FutureBuilder] to await the returned directory or show a loading indicator; this shouldn't cause any interference. If creating a path manually, be sure it's the correct format, use the `path` library if needed.
  ///
  /// Required.
  final CacheDirectory parentDirectory;

  /// The name of the cache store to use for this instance
  ///
  /// Defaults to the default store, 'mainStore'.
  final String storeName;

  /// The behavior method to get and cache a tile
  ///
  /// Defaults to [CacheBehavior.cacheFirst] - get tiles from the local cache, going on the Internet to update the cached tile if it has expired ([cachedValidDuration] has passed).
  final CacheBehavior behavior;

  /// The duration until a tile expires and needs to be fetched again when browsing
  ///
  /// Defaults to 16 days, set to [Duration.zero] to disable.
  final Duration cachedValidDuration;

  /// The maximum number of tiles allowed in a cache store (only whilst 'browsing' - see below) before the oldest tile gets deleted
  ///
  /// Only applies to 'browse caching', ie. downloading regions will bypass this limit. This can be computationally expensive as it potentially involves sorting through this many files to find the oldest file.
  ///
  /// Please note that this limit is a 'suggestion'. Due to the nature of the application, it is difficult to set a hard limit on a the store's length. Therefore, fast browsing may go above this limit.
  ///
  /// Defaults to 20000, set to 0 to disable.
  final int maxStoreLength;

  /// Automatically generated. Contains the absolute path to the cache store after initialization.
  final String storePath;

  /// Used internally for recovery purposes
  bool _downloadOngoing = false;

  /// Used internally for browsing-caused tile requests
  http.Client _httpClient = http.Client();

  /// Used internally to queue download tiles to process in bulk
  Queue? _queue;

  /// Used internally to control bulk downloading
  StreamController<List>? _streamController;

  /// Create a `TileProvider` to automatically cache browsed (panned over) tiles to a local caching database. Also contains methods to download regions of a map to a local caching database using an instance.
  ///
  /// Requires a valid cache directory: [parentDirectory]. [storeName] defaults to the default store, 'mainStore', but can be overriden to different stores. On initialisation, automatically creates the cache store if it does not exist.
  ///
  /// Optionally adjust:
  ///  - [maxStoreLength] - the number of tiles that can be stored at once in this cache store
  ///  - [behavior] - the caching behavior to use, affecting [cachedValidDuration]
  ///  - [cachedValidDuration] -  the length of time a cached tile is valid before needing to be updated in some caching behaviors
  ///
  /// See each property's individual documentation for more detail.
  StorageCachingTileProvider({
    required this.parentDirectory,
    this.storeName = 'mainStore',
    this.behavior = CacheBehavior.cacheFirst,
    this.cachedValidDuration = const Duration(days: 16),
    this.maxStoreLength = 20000,
  }) : storePath = p.joinAll([parentDirectory.absolute.path, storeName]) {
    Directory(storePath).createSync(recursive: true);
  }

  /// Converts a [MapCachingManager] to [StorageCachingTileProvider], using the same [parentDirectory] and [storeName].
  ///
  /// For more information about this constructor, see the main class [StorageCachingTileProvider].
  StorageCachingTileProvider.fromMapCachingManager(
    MapCachingManager mapCachingManager, {
    this.behavior = CacheBehavior.cacheFirst,
    this.cachedValidDuration = const Duration(days: 16),
    this.maxStoreLength = 20000,
  })  : parentDirectory = mapCachingManager.parentDirectory,
        storeName = mapCachingManager.storeName,
        storePath = p.joinAll([
          mapCachingManager.parentDirectory.absolute.path,
          mapCachingManager.storeName
        ]) {
    Directory(storePath).createSync(recursive: true);
  }

  /// Always call (if necessary) after finishing with caching, or in your widget's dispose methods
  ///
  /// Ensures the internal stream controller is closed, the internal HTTP client is closed, and the internal queue controller is cancelled. If you require this provider again, you will need to reconstruct it.
  @override
  void dispose() {
    super.dispose();
    _httpClient.close();
    if (!(_queue?.isCancelled ?? true)) _queue?.cancel();
    if (!(_streamController?.isClosed ?? true)) _streamController?.close();
  }

  /// Get a browsed tile as an image, paint it on the map and save it's bytes to cache for later
  @override
  ImageProvider getImage(Coords<num> coords, TileLayerOptions options) =>
      FMTCImageProvider(
        provider: this,
        options: options,
        coords: coords,
        httpClient: _httpClient,
      );

  //! GENERAL DOWNLOADING !//

  /// Download a specified [DownloadableRegion] in the foreground
  ///
  /// To check the number of tiles that need to be downloaded before using this function, use [checkRegion].
  ///
  /// Unless otherwise specified, also starts a recovery session.
  ///
  /// For more information on [preDownloadChecksCallback], see documentation on [PreDownloadChecksCallback]. In a few words, use this callback to check the devices information/status before starting a download.
  ///
  /// Streams a [DownloadProgress] object containing lots of handy information about the download's progression status; unless the pre-download checks fail, in which case the stream's `.isEmpty` will be `true` and no new events will be emitted. If you get messages about 'Bad State' after dealing with the checks, just add `.asBroadcastStream()` on the end of [downloadRegion].
  Stream<DownloadProgress> downloadRegion(
    DownloadableRegion region, {
    bool disableRecovery = false,
    required PreDownloadChecksCallback preDownloadChecksCallback,
  }) async* {
    if (preDownloadChecksCallback != null) {
      final ConnectivityResult connectivity =
          await Connectivity().checkConnectivity();

      late final int? batteryLevel;
      late final ChargingStatus? chargingStatus;
      if (Platform.isAndroid) {
        final _info = await BatteryInfoPlugin().androidBatteryInfo;
        batteryLevel = _info?.batteryLevel;
        chargingStatus = _info?.chargingStatus;
      } else if (Platform.isIOS) {
        final _info = await BatteryInfoPlugin().iosBatteryInfo;
        batteryLevel = _info?.batteryLevel;
        chargingStatus = _info?.chargingStatus;
      } else
        throw FallThroughError();

      final bool? result = await preDownloadChecksCallback(
          connectivity, batteryLevel, chargingStatus);

      if ((result == null &&
              (connectivity == ConnectivityResult.mobile ||
                  connectivity == ConnectivityResult.none ||
                  !((batteryLevel ?? 50) > 15 ||
                      chargingStatus == ChargingStatus.Charging))) ||
          result == false) {
        return;
      }
    }

    if (!disableRecovery) {
      if (!MapCachingManager(parentDirectory, storeName).startInternalRecovery(
        region.type,
        region.originalRegion,
        region.minZoom,
        region.maxZoom,
        region.preventRedownload,
        region.seaTileRemoval,
      ))
        throw StateError(
            'Failed to create recovery session. Restart app and retry. If issue persists, disable recovery to continue.');
      _downloadOngoing = true;
    }

    _queue = Queue(parallel: region.parallelThreads);
    _streamController = StreamController();

    yield* _startDownload(
      region: region,
      tiles: await compute(
        region.type == RegionType.rectangle
            ? rectangleTiles
            : region.type == RegionType.circle
                ? circleTiles
                : lineTiles,
        {
          'bounds': LatLngBounds.fromPoints(region.points),
          'circleOutline': region.points,
          'lineOutline': region.points.chunked(4),
          'minZoom': region.minZoom,
          'maxZoom': region.maxZoom,
          'crs': region.crs,
          'tileSize':
              CustomPoint(region.options.tileSize, region.options.tileSize),
        },
      ),
    );
  }

  /// Check approximately how many downloadable tiles are within a specified [DownloadableRegion]
  ///
  /// This does not take into account sea tile removal or redownload prevention, as these are handled in the download area of the code.
  ///
  /// Returns an `int` which is the number of tiles.
  static Future<int> checkRegion(DownloadableRegion region) async =>
      (await compute(
        region.type == RegionType.rectangle
            ? rectangleTiles
            : region.type == RegionType.circle
                ? circleTiles
                : lineTiles,
        {
          'bounds': LatLngBounds.fromPoints(region.points),
          'circleOutline': region.points,
          'lineOutline': region.points.chunked(4),
          'minZoom': region.minZoom,
          'maxZoom': region.maxZoom,
          'crs': region.crs,
          'tileSize':
              CustomPoint(region.options.tileSize, region.options.tileSize),
        },
      ))
          .length;

  /// Cancels the ongoing foreground download and recovery session (within the current object)
  ///
  /// Do not use to cancel background downloads, return `true` from the background download callback to cancel a background download. Background download cancellations require a few more 'shut-down' steps that can create unexpected issues and memory leaks if not carried out.
  ///
  /// Should remain silent if there was no ongoing download.
  void cancelDownload() {
    _queue?.dispose();
    _streamController?.close();
    MapCachingManager(parentDirectory, storeName).endInternalRecovery();
    _downloadOngoing = false;
  }

  /// Recover a download that has been stopped without the correct methods, for example after closing the app during a download
  ///
  /// Returns `null` if there is no recoverable download, otherwise returns a [RecoveredRegion] containing the salvaged data. Use `.toDownloadable` on the region to recieve a [DownloadableRegion], which can be passed normally to other functions.
  ///
  /// Optionally make [deleteRecovery] `false` if you would like the download to still be recoverable after this method has been called.
  ///
  /// How does recovery work? At the start of a download, a file is created including information about the download. At the end of a download or when a download is correctly cancelled, this file is deleted. However, if there is no ongoing download (controlled by an internal variable) and the recovery file exists, the download has obviously been stopped incorrectly, meaning it can be recovered using the information within the recovery file.
  RecoveredRegion? recoverDownload({bool deleteRecovery = true}) {
    if (_downloadOngoing) return null;

    final RecoveredRegion? recovered =
        MapCachingManager(parentDirectory, storeName)
            .recoverDownloadInternally();

    if (recovered == null) return null;

    if (deleteRecovery)
      MapCachingManager(parentDirectory, storeName).endInternalRecovery();

    return recovered;
  }

  //! BACKGROUND DOWNLOADING !//

  /// Requests for app to be excluded from battery optimizations to aid running a background process
  ///
  /// Only available on Android devices, due to limitations with other operating systems.
  ///
  /// Background downloading is complicated: see the main README for more information.
  ///
  /// Pops up an intrusive system dialog asking to be given the permission. There is no explanation for the user, except that the app will be allowed to run in the background all the time, so less technical users may be put off. It is up to you to decide (and program accordingly) if you want to show a reason first, then request the permission.
  ///
  /// Will return (`Future`) `true` if permission was granted, `false` if the permission was denied.
  static Future<bool> requestIgnoreBatteryOptimizations(
      BuildContext context) async {
    if (Platform.isAndroid) {
      final PermissionStatus status =
          await Permission.ignoreBatteryOptimizations.status;
      if (status.isDenied || status.isLimited) {
        final PermissionStatus statusAfter =
            await Permission.ignoreBatteryOptimizations.request();
        if (statusAfter.isGranted) return true;
        return false;
      } else if (status.isGranted)
        return true;
      else
        return false;
    } else
      throw UnsupportedError(
          'The background download feature is only available on Android due to limitations with other operating systems.');
  }

  /// Download a specified [DownloadableRegion] in the background, and show a notification progress bar (by default)
  ///
  /// Only available on Android devices, due to limitations with other operating systems.
  /// To check the number of tiles that need to be downloaded before using this function, use [checkRegion].
  ///
  /// Background downloading is complicated: see the main README for more information.
  ///
  /// You may want to call [requestIgnoreBatteryOptimizations] beforehand, depending on how/where/why this background download will be used. See documentation on that method for more information.
  ///
  /// Optionally specify [showNotification] as `false` to disable the built-in notification system.
  ///
  /// Optionally specify a [callback] that gets fired every time another tile is downloaded/failed, takes one [DownloadProgress] argument, and returns a boolean. Download can be cancelled by returning `true` from [callback] function.
  ///
  /// If the download doesn't seem to start on a device, try changing [useAltMethod] to `true`. This will switch to an older Android API, so should only be used if it is the most stable on a device. You may be able to programatically detect if the download hasn't started by using the callback, therefore allowing you to call this method again with [useAltMethod], but this isn't guranteed.
  ///
  /// For more information on [preDownloadChecksCallback], see documentation on [PreDownloadChecksCallback]. In a few words, use this callback to check the devices information/status before starting a download. [preDownloadChecksFailedCallback] is optional and will be called if the checks do fail, after cancelling the download.
  ///
  /// Returns nothing.
  void downloadRegionBackground(
    DownloadableRegion region,
    StorageCachingTileProvider provider, {
    bool showNotification = true,
    bool Function(DownloadProgress)? callback,
    required PreDownloadChecksCallback preDownloadChecksCallback,
    void Function()? preDownloadChecksFailedCallback,
    bool useAltMethod = false,
    String notificationChannelName = 'Map Background Downloader',
    String notificationChannelDescription =
        'Displays progress notifications to inform the user about the progress of their map download.',
    String notificationIcon = '@mipmap/ic_launcher',
    String subText = 'Map Downloader',
    String ongoingTitle = 'Map Downloading...',
    String Function(DownloadProgress)? ongoingBodyBuilder,
    String cancelledTitle = 'Map Download Cancelled',
    String Function(DownloadProgress)? cancelledBodyBuilder,
    String completeTitle = 'Map Downloaded',
    String Function(DownloadProgress)? completeBodyBuilder,
  }) async {
    if (Platform.isAndroid) {
      FlutterLocalNotificationsPlugin? flutterLocalNotificationsPlugin;
      flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
      final AndroidInitializationSettings initializationSettingsAndroid =
          AndroidInitializationSettings(notificationIcon);
      final InitializationSettings initializationSettings =
          InitializationSettings(android: initializationSettingsAndroid);
      await flutterLocalNotificationsPlugin.initialize(initializationSettings);

      await BackgroundFetch.configure(
        BackgroundFetchConfig(
          minimumFetchInterval: 15,
        ),
        (String taskId) async {
          if (taskId == 'backgroundTileDownload') {
            // ignore: cancel_subscriptions
            StreamSubscription<DownloadProgress>? sub;
            final download = downloadRegion(
              region,
              preDownloadChecksCallback: preDownloadChecksCallback,
            ).asBroadcastStream();
            if (await download.isEmpty) {
              cancelDownload();
              if (preDownloadChecksFailedCallback != null)
                preDownloadChecksFailedCallback();
              BackgroundFetch.finish(taskId);
              return;
            }

            sub = download.listen((event) async {
              AndroidNotificationDetails androidPlatformChannelSpecifics =
                  AndroidNotificationDetails(
                'MapDownloading',
                notificationChannelName,
                channelDescription: notificationChannelDescription,
                showProgress: true,
                maxProgress: event.maxTiles,
                progress: event.attemptedTiles,
                visibility: NotificationVisibility.public,
                subText: subText,
                importance: Importance.low,
                priority: Priority.low,
                showWhen: false,
                playSound: false,
                enableLights: false,
                enableVibration: false,
                onlyAlertOnce: true,
                autoCancel: false,
              );
              NotificationDetails platformChannelSpecifics =
                  NotificationDetails(android: androidPlatformChannelSpecifics);
              if (showNotification) {
                await flutterLocalNotificationsPlugin!.show(
                  0,
                  ongoingTitle,
                  ongoingBodyBuilder == null
                      ? '${event.attemptedTiles}/${event.maxTiles} (${event.percentageProgress.round().toString()}%)'
                      : ongoingBodyBuilder(event),
                  platformChannelSpecifics,
                );
              }

              if (callback != null && callback(event)) {
                sub!.cancel();
                cancelDownload();
                if (showNotification) {
                  flutterLocalNotificationsPlugin!.cancel(0);
                  await flutterLocalNotificationsPlugin.show(
                    0,
                    cancelledTitle,
                    cancelledBodyBuilder == null
                        ? '${event.remainingTiles} tiles remained'
                        : cancelledBodyBuilder(event),
                    platformChannelSpecifics,
                  );
                }
                BackgroundFetch.finish(taskId);
              }

              if (event.percentageProgress == 100) {
                sub!.cancel();
                cancelDownload();
                if (showNotification) {
                  flutterLocalNotificationsPlugin!.cancel(0);
                  await flutterLocalNotificationsPlugin.show(
                    0,
                    completeTitle,
                    completeBodyBuilder == null
                        ? '${event.failedTiles.length} failed tiles'
                        : completeBodyBuilder(event),
                    platformChannelSpecifics,
                  );
                }
                BackgroundFetch.finish(taskId);
              }
            });
          } else
            BackgroundFetch.finish(taskId);
        },
        (String taskId) async => BackgroundFetch.finish(taskId),
      );
      await BackgroundFetch.scheduleTask(
        TaskConfig(
          taskId: 'backgroundTileDownload',
          delay: 1,
          forceAlarmManager: useAltMethod,
        ),
      );
    } else
      throw UnsupportedError(
          'The background download feature is only available on Android due to limitations with other operating systems.');
  }

  //! DOWNLOAD FUNCTIONS !//

  Stream<DownloadProgress> _startDownload({
    required DownloadableRegion region,
    required List<Coords<num>> tiles,
  }) async* {
    final http.Client client = http.Client();

    Uint8List? seaTileBytes;
    if (region.seaTileRemoval)
      seaTileBytes = (await client.get(
        Uri.parse(this.getTileUrl(Coords(0, 0)..z = 19, region.options)),
      ))
          .bodyBytes;

    int successfulTiles = 0;
    List<String> failedTiles = [];
    int seaTiles = 0;
    int existingTiles = 0;
    final DateTime startTime = DateTime.now();

    final Stream<List<dynamic>> downloadStream = bulkDownloader(
      tiles: tiles,
      provider: this,
      options: region.options,
      client: client,
      parallelThreads: region.parallelThreads,
      errorHandler: region.errorHandler,
      preventRedownload: region.preventRedownload,
      seaTileBytes: seaTileBytes,
      queue: _queue!,
      streamController: _streamController!,
    );

    await for (List<dynamic> event in downloadStream) {
      successfulTiles += event[0] as int;
      if (event[1] != '') failedTiles.add(event[1]);
      seaTiles += event[2] as int;
      existingTiles += event[3] as int;

      final DownloadProgress prog = DownloadProgress.internal(
        maxTiles: tiles.length,
        successfulTiles: successfulTiles,
        failedTiles: failedTiles,
        seaTiles: seaTiles,
        existingTiles: existingTiles,
        duration: DateTime.now().difference(startTime),
      );
      yield prog;
      if (prog.percentageProgress >= 100) cancelDownload();
    }

    client.close();
  }
}
