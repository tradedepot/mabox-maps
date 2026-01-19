part of mapbox_gl_web;

const _mapboxGlCssUrl =
    'https://api.mapbox.com/mapbox-gl-js/v2.14.1/mapbox-gl.css';

/// Converts nested Dart coordinate arrays to JS arrays for WASM compatibility.
/// This handles Point [lng, lat], LineString [[lng, lat], ...], and Polygon [[[lng, lat], ...], ...] geometries.
JSAny? _coordinatesToJs(dynamic coords) {
  if (coords == null) return null;
  if (coords is num) return coords.toJS;
  if (coords is List) {
    final jsArray = <JSAny?>[];
    for (final item in coords) {
      jsArray.add(_coordinatesToJs(item));
    }
    return jsArray.toJS;
  }
  // Fallback for other types
  return coords.toString().toJS;
}

class MapboxWebGlPlatform extends MapboxGlPlatform
    implements MapboxMapOptionsSink {
  late web.HTMLDivElement _mapElement;

  late Map<String, dynamic> _creationParams;
  late MapboxMap _map;
  bool _mapReady = false;
  dynamic _draggedFeatureId;
  LatLng? _dragOrigin;
  LatLng? _dragPrevious;
  bool _dragEnabled = true;
  final _addedFeaturesByLayer = <String, FeatureCollection>{};

  final _interactiveFeatureLayerIds = Set<String>();

  bool _trackCameraPosition = false;
  GeolocateControl? _geolocateControl;
  LatLng? _myLastLocation;

  String? _navigationControlPosition;
  NavigationControl? _navigationControl;
  Timer? lastResizeObserverTimer;

  @override
  Widget buildView(
      Map<String, dynamic> creationParams,
      OnPlatformViewCreatedCallback onPlatformViewCreated,
      Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers) {
    _creationParams = creationParams;
    _registerViewFactory(onPlatformViewCreated, this.hashCode);
    return HtmlElementView(
        viewType: 'plugins.flutter.io/mapbox_gl_${this.hashCode}');
  }

  @override
  void dispose() {
    super.dispose();
    _map.remove();
  }

  void _registerViewFactory(Function(int) callback, int identifier) {
    // ignore: undefined_prefixed_name
    ui.platformViewRegistry.registerViewFactory(
        'plugins.flutter.io/mapbox_gl_$identifier', (int viewId) {
      _mapElement = web.HTMLDivElement()
        ..style.position = 'absolute'
        ..style.top = '0'
        ..style.left = '0'
        ..style.width = '100%'
        ..style.height = '100%'; // Required for WASM/Skwasm compatibility
      callback(viewId);
      return _mapElement;
    });
  }

  @override
  Future<void> initPlatform(int id) async {
    try {
      // Add stylesheet (will timeout gracefully if already loaded in index.html)
      await _addStylesheetToShadowRoot(_mapElement);

      // Ensure element is attached and has dimensions
      await _waitForElementReady();

      if (_creationParams.containsKey('initialCameraPosition')) {
        var camera = _creationParams['initialCameraPosition'];
        _dragEnabled = _creationParams['dragEnabled'] ?? true;

        // Set access token
        if (_creationParams.containsKey('accessToken')) {
          final mapboxgl = (web.window as JSObject).getProperty('mapboxgl'.toJS)
              as JSObject?;
          if (mapboxgl != null) {
            final token = _creationParams['accessToken'] as String?;
            if (token != null && token.isNotEmpty) {
              mapboxgl.setProperty('accessToken'.toJS, token.toJS);
            }
          } else {
            print(
                'Warning: mapboxgl not found on window. Make sure mapbox-gl.js is loaded.');
          }
        }

        // Extract camera parameters with null safety
        final target = camera['target'];
        final double lat = target != null && target is List && target.length > 0
            ? (target[0] as num).toDouble()
            : 0.0;
        final double lng = target != null && target is List && target.length > 1
            ? (target[1] as num).toDouble()
            : 0.0;
        final double zoom = (camera['zoom'] as num?)?.toDouble() ?? 0.0;
        final double bearing = (camera['bearing'] as num?)?.toDouble() ?? 0.0;
        final double pitch = (camera['tilt'] as num?)?.toDouble() ?? 0.0;

        _map = MapboxMap(
          MapOptions(
            container: _mapElement,
            style: 'mapbox://styles/mapbox/streets-v11',
            center: LngLat(lng, lat),
            zoom: zoom,
            bearing: bearing,
            pitch: pitch,
            preserveDrawingBuffer: true,
          ),
        );

        // Add error handler
        _map.on('error', (e) {
          print('Mapbox map error: $e');
        });

        // Wait for the map to fully load before completing initialization
        // This prevents vec4.js errors from Mapbox's internal mouse handlers
        final loadCompleter = Completer<void>();

        _map.on('load', (e) {
          _onStyleLoaded(e);

          // Register interaction events after map is fully loaded
          _registerClickHandler();
          // long click not available in web, so it is mapped to double click
          _map.on('dblclick', _onMapLongClick);

          if (_dragEnabled) {
            _map.on('mouseup', _onMouseUp);
            _map.on('mousemove', _onMouseMove);
          }

          // Signal that map is ready
          if (!loadCompleter.isCompleted) {
            loadCompleter.complete();
          }
        });

        // These events are safe to register before load
        _map.on('movestart', _onCameraMoveStarted);
        _map.on('move', _onCameraMove);
        _map.on('moveend', _onCameraIdle);
        _map.on('resize', (_) => _onMapResize());
        _map.on('styleimagemissing', _loadFromAssets);

        _initResizeObserver();

        // Wait for map to be fully loaded with a timeout
        await loadCompleter.future.timeout(
          Duration(seconds: 30),
          onTimeout: () {
            print('Warning: Map load timed out after 30 seconds');
          },
        );
      }

      Convert.interpretMapboxMapOptions(_creationParams['options'], this);
    } catch (e) {
      // Log error but don't rethrow - the map may still work despite initialization issues
      print('Mapbox initialization warning: $e');
    }
  }

  void _initResizeObserver() {
    final resizeObserver = web.ResizeObserver(
        (JSArray<web.ResizeObserverEntry> entries,
            web.ResizeObserver observer) {
      // The resize observer might be called a lot of times when the user resizes the browser window with the mouse for example.
      // Due to the fact that the resize call is quite expensive it should not be called for every triggered event but only the last one, like "onMoveEnd".
      // But because there is no event type for the end, there is only the option to spawn timers and cancel the previous ones if they get overwritten by a new event.
      lastResizeObserverTimer?.cancel();
      lastResizeObserverTimer = Timer(Duration(milliseconds: 50), () {
        _onMapResize();
      });
    }.toJS);
    resizeObserver.observe(web.document.body as web.Element);
  }

  void _loadFromAssets(Event event) async {
    final imagePath = event.id;
    final ByteData bytes = await rootBundle.load(imagePath);
    await addImage(imagePath, bytes.buffer.asUint8List());
  }

  _onMouseDown(Event e) {
    var isDraggable = e.features[0].properties['draggable'];
    if (isDraggable != null && isDraggable) {
      // Prevent the default map drag behavior.
      e.preventDefault();
      _draggedFeatureId = e.features[0].id;
      _map.getCanvas().style.cursor = 'grabbing';
      var coords = e.lngLat;
      _dragOrigin = LatLng(coords.lat as double, coords.lng as double);

      if (_draggedFeatureId != null) {
        final current =
            LatLng(e.lngLat.lat.toDouble(), e.lngLat.lng.toDouble());
        final payload = {
          'id': _draggedFeatureId,
          'point': Point<double>(e.point.x.toDouble(), e.point.y.toDouble()),
          'origin': _dragOrigin,
          'current': current,
          'delta': LatLng(0, 0),
          'eventType': 'start'
        };
        onFeatureDraggedPlatform(payload);
      }
    }
  }

  _onMouseUp(Event e) {
    if (_draggedFeatureId != null) {
      final current = LatLng(e.lngLat.lat.toDouble(), e.lngLat.lng.toDouble());
      final payload = {
        'id': _draggedFeatureId,
        'point': Point<double>(e.point.x.toDouble(), e.point.y.toDouble()),
        'origin': _dragOrigin,
        'current': current,
        'delta': current - (_dragPrevious ?? _dragOrigin!),
        'eventType': 'end'
      };
      onFeatureDraggedPlatform(payload);
    }
    _draggedFeatureId = null;
    _dragPrevious = null;
    _dragOrigin = null;
    _map.getCanvas().style.cursor = '';
  }

  _onMouseMove(Event e) {
    if (_draggedFeatureId != null) {
      final current = LatLng(e.lngLat.lat.toDouble(), e.lngLat.lng.toDouble());
      final payload = {
        'id': _draggedFeatureId,
        'point': Point<double>(e.point.x.toDouble(), e.point.y.toDouble()),
        'origin': _dragOrigin,
        'current': current,
        'delta': current - (_dragPrevious ?? _dragOrigin!),
        'eventType': 'drag'
      };
      _dragPrevious = current;
      onFeatureDraggedPlatform(payload);
    }
  }

  /// Wait for the map element to be properly laid out in the DOM with valid dimensions
  Future<void> _waitForElementReady() async {
    // Wait up to 2 seconds for element to have valid dimensions
    for (int i = 0; i < 40; i++) {
      final width = _mapElement.offsetWidth;
      final height = _mapElement.offsetHeight;

      if (width > 0 && height > 0) {
        return;
      }

      await Future.delayed(Duration(milliseconds: 50));
    }

    // If still no dimensions, log a warning but continue
    print(
        'Warning: Map element may have zero dimensions. Map rendering may fail.');
  }

  Future<void> _addStylesheetToShadowRoot(web.HTMLElement e) async {
    try {
      web.HTMLLinkElement link = web.HTMLLinkElement()
        ..href = _mapboxGlCssUrl
        ..rel = 'stylesheet';
      e.append(link);

      // Use a timeout to avoid hanging if stylesheet fails to load
      bool loaded = false;
      link.onLoad.first.then((_) => loaded = true);

      // Wait up to 5 seconds for the stylesheet to load
      for (int i = 0; i < 50 && !loaded; i++) {
        await Future.delayed(Duration(milliseconds: 100));
      }

      if (!loaded) {
        print('Warning: Mapbox CSS stylesheet load timed out, continuing...');
      }
    } catch (e) {
      print('Warning: Failed to load Mapbox CSS: $e');
      // Continue anyway - CSS might already be loaded in index.html
    }
  }

  @override
  Future<CameraPosition?> updateMapOptions(
      Map<String, dynamic> optionsUpdate) async {
    // FIX: why is called indefinitely? (map_ui page)
    Convert.interpretMapboxMapOptions(optionsUpdate, this);
    return _getCameraPosition();
  }

  @override
  Future<bool?> animateCamera(CameraUpdate cameraUpdate,
      {Duration? duration}) async {
    final cameraOptions = Convert.toCameraOptions(cameraUpdate, _map);

    final jsObj = cameraOptions.jsObject;
    final around = jsObj.around;
    final bearing = jsObj.bearing;
    final center = jsObj.center;
    final pitch = jsObj.pitch;
    final zoom = jsObj.zoom;

    _map.flyTo({
      if (around != null) 'around': around,
      if (bearing != null) 'bearing': bearing,
      if (center != null) 'center': center,
      if (pitch != null) 'pitch': pitch,
      if (zoom != null) 'zoom': zoom,
      if (duration != null) 'duration': duration.inMilliseconds,
    });

    return true;
  }

  @override
  Future<bool?> moveCamera(CameraUpdate cameraUpdate) async {
    final cameraOptions = Convert.toCameraOptions(cameraUpdate, _map);
    _map.jumpTo(cameraOptions);
    return true;
  }

  @override
  Future<void> updateMyLocationTrackingMode(
      MyLocationTrackingMode myLocationTrackingMode) async {
    setMyLocationTrackingMode(myLocationTrackingMode.index);
  }

  @override
  Future<void> matchMapLanguageWithDeviceDefault() async {
    setMapLanguage(
        WidgetsBinding.instance.platformDispatcher.locale.languageCode);
  }

  @override
  Future<void> setMapLanguage(String language) async {
    // Convert Dart list to JS value for WASM compatibility
    _map.setLayoutProperty(
      'country-label',
      'text-field',
      ['get', 'name_' + language].jsify(),
    );
  }

  @override
  Future<void> setTelemetryEnabled(bool enabled) async {
    print('Telemetry not available in web');
    return;
  }

  @override
  Future<bool> getTelemetryEnabled() async {
    print('Telemetry not available in web');
    return false;
  }

  @override
  Future<List> queryRenderedFeatures(
      Point<double> point, List<String> layerIds, List<Object>? filter) async {
    Map<String, dynamic> options = {};
    if (layerIds.length > 0) {
      options['layers'] = layerIds;
    }
    if (filter != null) {
      options['filter'] = filter;
    }

    // avoid issues with the js point type
    final pointAsList = [point.x, point.y];
    return _map
        .queryRenderedFeatures([pointAsList, pointAsList], options)
        .map((feature) => {
              'type': 'Feature',
              'id': feature.id,
              'geometry': {
                'type': feature.geometry.type,
                'coordinates': feature.geometry.coordinates,
              },
              'properties': feature.properties,
              'source': feature.source,
            })
        .toList();
  }

  @override
  Future<List> queryRenderedFeaturesInRect(
      Rect rect, List<String> layerIds, String? filter) async {
    Map<String, dynamic> options = {};
    if (layerIds.length > 0) {
      options['layers'] = layerIds;
    }
    if (filter != null) {
      options['filter'] = filter;
    }
    return _map
        .queryRenderedFeatures([
          [rect.left, rect.bottom],
          [rect.right, rect.top],
        ], options)
        .map((feature) => {
              'type': 'Feature',
              'id': feature.id,
              'geometry': {
                'type': feature.geometry.type,
                'coordinates': feature.geometry.coordinates,
              },
              'properties': feature.properties,
              'source': feature.source,
            })
        .toList();
  }

  @override
  Future invalidateAmbientCache() async {
    print('Offline storage not available in web');
  }

  @override
  Future<LatLng?> requestMyLocationLatLng() async {
    return _myLastLocation;
  }

  @override
  Future<LatLngBounds> getVisibleRegion() async {
    final bounds = _map.getBounds();
    return LatLngBounds(
      southwest: LatLng(
        bounds.getSouthWest().lat as double,
        bounds.getSouthWest().lng as double,
      ),
      northeast: LatLng(
        bounds.getNorthEast().lat as double,
        bounds.getNorthEast().lng as double,
      ),
    );
  }

  @override
  Future<void> addImage(String name, Uint8List bytes,
      [bool sdf = false]) async {
    final photo = decodeImage(bytes);
    if (photo == null) {
      print('Warning: Could not decode image for $name');
      return;
    }

    if (_map.hasImage(name)) {
      return; // Image already exists
    }

    // Get raw RGBA bytes from the decoded image
    final imageBytes = photo.getBytes();

    // Create image data object - Mapbox expects { width, height, data: Uint8Array }
    // Pass data as Uint8List and let jsifyAny convert it
    final imageData = <String, dynamic>{
      'width': photo.width,
      'height': photo.height,
      'data': imageBytes,
    };

    // Pass as Map - jsifyAny in map.dart will convert it
    _map.addImage(name, imageData, {'sdf': sdf});
  }

  @override
  Future<void> removeSource(String sourceId) async {
    _map.removeSource(sourceId);
  }

  CameraPosition? _getCameraPosition() {
    if (_trackCameraPosition) {
      final center = _map.getCenter();
      return CameraPosition(
        bearing: _map.getBearing() as double,
        target: LatLng(center.lat as double, center.lng as double),
        tilt: _map.getPitch() as double,
        zoom: _map.getZoom() as double,
      );
    }
    return null;
  }

  void _onStyleLoaded(_) {
    _mapReady = true;
    _onMapResize();
    onMapStyleLoadedPlatform(null);
  }

  void _onMapResize() {
    Timer(Duration(), () {
      var container = _map.getContainer();
      var canvas = _map.getCanvas();
      var widthMismatch = canvas.clientWidth != container.clientWidth;
      var heightMismatch = canvas.clientHeight != container.clientHeight;
      if (widthMismatch || heightMismatch) {
        _map.resize();
      }
    });
  }

  void _registerClickHandler() async {
    // Wait for map to be truly loaded
    while (!_map.loaded()) {
      await Future.delayed(Duration(milliseconds: 50));
    }
    
    // Use direct canvas click listener since Mapbox's on('click') 
    // doesn't work reliably with Flutter web's JS interop
    final canvas = _map.getCanvas();
    canvas.addEventListener('click', ((web.MouseEvent e) {
      _handleCanvasClick(e.offsetX.toDouble(), e.offsetY.toDouble());
    }).toJS);
  }

  void _handleCanvasClick(double x, double y) {
    // Convert screen coordinates to geographic coordinates
    final lngLat = _map.unproject(mapbox.Point(x, y));
    
    // Query features at click point
    final point = [[x, y], [x, y]];
    final features = _map.queryRenderedFeatures(point,
        {"layers": _interactiveFeatureLayerIds.toList()});
    final payload = {
      'point': Point<double>(x, y),
      'latLng': LatLng(lngLat.lat as double, lngLat.lng as double),
      if (features.isNotEmpty) "id": features.first.id,
    };
    if (features.isNotEmpty) {
      onFeatureTappedPlatform(payload);
    } else {
      onMapClickPlatform(payload);
    }
  }


  void _onMapLongClick(e) {
    onMapLongClickPlatform({
      'point': Point<double>(e.point.x, e.point.y),
      'latLng': LatLng(e.lngLat.lat, e.lngLat.lng),
    });
  }

  void _onCameraMoveStarted(_) {
    onCameraMoveStartedPlatform(null);
  }

  void _onCameraMove(_) {
    final center = _map.getCenter();
    var camera = CameraPosition(
      bearing: _map.getBearing() as double,
      target: LatLng(center.lat as double, center.lng as double),
      tilt: _map.getPitch() as double,
      zoom: _map.getZoom() as double,
    );
    onCameraMovePlatform(camera);
  }

  void _onCameraIdle(_) {
    final center = _map.getCenter();
    var camera = CameraPosition(
      bearing: _map.getBearing() as double,
      target: LatLng(center.lat as double, center.lng as double),
      tilt: _map.getPitch() as double,
      zoom: _map.getZoom() as double,
    );
    onCameraIdlePlatform(camera);
  }

  void _onCameraTrackingChanged(bool isTracking) {
    if (isTracking) {
      onCameraTrackingChangedPlatform(MyLocationTrackingMode.Tracking);
    } else {
      onCameraTrackingChangedPlatform(MyLocationTrackingMode.None);
    }
  }

  void _onCameraTrackingDismissed() {
    onCameraTrackingDismissedPlatform(null);
  }

  void _addGeolocateControl({bool trackUserLocation = false}) {
    _removeGeolocateControl();
    _geolocateControl = GeolocateControl(
      GeolocateControlOptions(
        positionOptions: PositionOptions(enableHighAccuracy: true),
        trackUserLocation: trackUserLocation,
        showAccuracyCircle: true,
        showUserLocation: true,
      ),
    );
    _geolocateControl!.on('geolocate', (e) {
      _myLastLocation = LatLng(e.coords.latitude, e.coords.longitude);
      onUserLocationUpdatedPlatform(UserLocation(
          position: LatLng(e.coords.latitude, e.coords.longitude),
          altitude: e.coords.altitude,
          bearing: e.coords.heading,
          speed: e.coords.speed,
          horizontalAccuracy: e.coords.accuracy,
          verticalAccuracy: e.coords.altitudeAccuracy,
          heading: null,
          timestamp: DateTime.fromMillisecondsSinceEpoch(e.timestamp)));
    });
    _geolocateControl!.on('trackuserlocationstart', (_) {
      _onCameraTrackingChanged(true);
    });
    _geolocateControl!.on('trackuserlocationend', (_) {
      _onCameraTrackingChanged(false);
      _onCameraTrackingDismissed();
    });
    _map.addControl(_geolocateControl, 'bottom-right');
  }

  void _removeGeolocateControl() {
    if (_geolocateControl != null) {
      _map.removeControl(_geolocateControl);
      _geolocateControl = null;
    }
  }

  void _updateNavigationControl({
    bool? compassEnabled,
    CompassViewPosition? position,
  }) {
    bool? prevShowCompass;
    if (_navigationControl != null) {
      prevShowCompass = _navigationControl!.options.showCompass;
    }
    String? prevPosition = _navigationControlPosition;

    String? positionString;
    switch (position) {
      case CompassViewPosition.TopRight:
        positionString = 'top-right';
        break;
      case CompassViewPosition.TopLeft:
        positionString = 'top-left';
        break;
      case CompassViewPosition.BottomRight:
        positionString = 'bottom-right';
        break;
      case CompassViewPosition.BottomLeft:
        positionString = 'bottom-left';
        break;
      default:
        positionString = null;
    }

    bool newShowComapss = compassEnabled ?? prevShowCompass ?? false;
    String? newPosition = positionString ?? prevPosition ?? null;

    _removeNavigationControl();
    _navigationControl = NavigationControl(NavigationControlOptions(
      showCompass: newShowComapss,
      showZoom: false,
      visualizePitch: false,
    ));

    if (newPosition == null) {
      _map.addControl(_navigationControl);
    } else {
      _map.addControl(_navigationControl, newPosition);
      _navigationControlPosition = newPosition;
    }
  }

  void _removeNavigationControl() {
    if (_navigationControl != null) {
      _map.removeControl(_navigationControl);
      _navigationControl = null;
    }
  }

  /*
   *  MapboxMapOptionsSink
   */
  @override
  void setAttributionButtonMargins(int x, int y) {
    print('setAttributionButtonMargins not available in web');
  }

  @override
  void setCameraTargetBounds(LatLngBounds? bounds) {
    if (bounds == null) {
      _map.setMaxBounds(null);
    } else {
      _map.setMaxBounds(
        LngLatBounds(
          LngLat(
            bounds.southwest.longitude,
            bounds.southwest.latitude,
          ),
          LngLat(
            bounds.northeast.longitude,
            bounds.northeast.latitude,
          ),
        ),
      );
    }
  }

  @override
  void setCompassEnabled(bool compassEnabled) {
    _updateNavigationControl(compassEnabled: compassEnabled);
  }

  @override
  void setCompassAlignment(CompassViewPosition position) {
    _updateNavigationControl(position: position);
  }

  @override
  void setAttributionButtonAlignment(AttributionButtonPosition position) {
    print('setAttributionButtonAlignment not available in web');
  }

  @override
  void setCompassViewMargins(int x, int y) {
    print('setCompassViewMargins not available in web');
  }

  @override
  void setLogoViewMargins(int x, int y) {
    print('setLogoViewMargins not available in web');
  }

  @override
  void setMinMaxZoomPreference(num? min, num? max) {
    // FIX: why is called indefinitely? (map_ui page)
    _map.setMinZoom(min);
    _map.setMaxZoom(max);
  }

  @override
  void setMyLocationEnabled(bool myLocationEnabled) {
    if (myLocationEnabled) {
      _addGeolocateControl(trackUserLocation: false);
    } else {
      _removeGeolocateControl();
    }
  }

  @override
  void setMyLocationRenderMode(int myLocationRenderMode) {
    print('myLocationRenderMode not available in web');
  }

  @override
  void setMyLocationTrackingMode(int myLocationTrackingMode) {
    if (_geolocateControl == null) {
      //myLocationEnabled is false, ignore myLocationTrackingMode
      return;
    }
    if (myLocationTrackingMode == 0) {
      _addGeolocateControl(trackUserLocation: false);
    } else {
      print('Only one tracking mode available in web');
      _addGeolocateControl(trackUserLocation: true);
    }
  }

  @override
  void setStyleString(String? styleString) {
    //remove old mouseenter callbacks to avoid multicalling
    for (var layerId in _interactiveFeatureLayerIds) {
      // Convert layerId to JSValue for WASM compatibility
      final jsLayerId = layerId.toJS;
      _map.off('mouseenter', jsLayerId, _onMouseEnterFeature);
      _map.off('mousemove', jsLayerId,
          _onMouseEnterFeature); // Fixed typo: mousemouve -> mousemove
      _map.off('mouseleave', jsLayerId, _onMouseLeaveFeature);
      if (_dragEnabled) _map.off('mousedown', jsLayerId, _onMouseDown);
    }
    _interactiveFeatureLayerIds.clear();

    try {
      final styleJson = jsonDecode(styleString ?? '');
      final styleJsObject = styleJson.jsify;
      _map.setStyle(styleJsObject);
    } catch (_) {
      _map.setStyle(styleString);
    }
    // catch style loaded for later style changes
    if (_mapReady) {
      _map.once("styledata", _onStyleLoaded);
    }
  }

  @override
  void setTrackCameraPosition(bool trackCameraPosition) {
    _trackCameraPosition = trackCameraPosition;
  }

  @override
  Future<Point> toScreenLocation(LatLng latLng) async {
    var screenPosition =
        _map.project(LngLat(latLng.longitude, latLng.latitude));
    return Point(screenPosition.x.round(), screenPosition.y.round());
  }

  @override
  Future<List<Point>> toScreenLocationBatch(Iterable<LatLng> latLngs) async {
    return latLngs.map((latLng) {
      var screenPosition =
          _map.project(LngLat(latLng.longitude, latLng.latitude));
      return Point(screenPosition.x.round(), screenPosition.y.round());
    }).toList(growable: false);
  }

  @override
  Future<LatLng> toLatLng(Point screenLocation) async {
    var lngLat =
        _map.unproject(mapbox.Point(screenLocation.x, screenLocation.y));
    return LatLng(lngLat.lat as double, lngLat.lng as double);
  }

  @override
  Future<double> getMetersPerPixelAtLatitude(double latitude) async {
    //https://wiki.openstreetmap.org/wiki/Zoom_levels
    var circumference = 40075017.686;
    var zoom = _map.getZoom();
    return circumference * cos(latitude * (pi / 180)) / pow(2, zoom + 9);
  }

  @override
  Future<void> removeLayer(String layerId) async {
    if (_map.getLayer(layerId) != null) {
      _interactiveFeatureLayerIds.remove(layerId);
      _map.removeLayer(layerId);
    }
  }

  @override
  Future<void> setFilter(String layerId, dynamic filter) async {
    _map.setFilter(layerId, filter);
  }

  @override
  Future<void> setVisibility(String layerId, bool isVisible) async {
    final layer = _map.getLayer(layerId);
    if (layer != null) {
      _map.setLayoutProperty(
          layerId, 'visibility', isVisible ? 'visible' : 'none');
    }
  }

  @override
  Future<void> addGeoJsonSource(String sourceId, Map<String, dynamic> geojson,
      {String? promoteId,
      bool cluster = false,
      int? clusterMaxZoom,
      int? clusterRadius}) async {
    final data = _makeFeatureCollection(geojson);
    _addedFeaturesByLayer[sourceId] = data;
    _map.addSource(sourceId, {
      "type": 'geojson',
      "data": geojson,
      if (promoteId != null) "promoteId": promoteId,
      if (cluster) "cluster": true,
      if (cluster && clusterMaxZoom != null) "clusterMaxZoom": clusterMaxZoom,
      if (cluster && clusterRadius != null) "clusterRadius": clusterRadius,
    });
  }

  Feature _makeFeature(Map<String, dynamic> geojsonFeature) {
    final coordinates = geojsonFeature["geometry"]["coordinates"];
    final type = geojsonFeature["geometry"]["type"]?.toString() ?? 'Point';
    // Properties stays as Dart Map (Feature expects Map<String, dynamic>)
    final properties = geojsonFeature["properties"] as Map<String, dynamic>?;

    // Convert coordinates to JS value for WASM compatibility
    // In dart2wasm, Dart collections must be explicitly converted to JS types
    final jsCoordinates = _coordinatesToJs(coordinates);

    return Feature(
        geometry: Geometry(type: type, coordinates: jsCoordinates),
        properties: properties,
        id: geojsonFeature["properties"]?["id"] ?? geojsonFeature["id"]);
  }

  FeatureCollection _makeFeatureCollection(Map<String, dynamic> geojson) {
    return FeatureCollection(
        features: [for (final f in geojson["features"] ?? []) _makeFeature(f)]);
  }

  @override
  Future<void> setGeoJsonSource(
      String sourceId, Map<String, dynamic> geojson) async {
    final source = _map.getSource(sourceId);
    if (source == null) {
      print('Warning: Source $sourceId not found, cannot set GeoJSON data');
      return;
    }
    final geoJsonSource = source as GeoJsonSource;
    final data = _makeFeatureCollection(geojson);
    _addedFeaturesByLayer[sourceId] = data;
    geoJsonSource.setData(data);
  }

  @override
  Future<void> addCircleLayer(
      String sourceId, String layerId, Map<String, dynamic> properties,
      {String? belowLayerId,
      String? sourceLayer,
      double? minzoom,
      double? maxzoom,
      dynamic filter,
      required bool enableInteraction}) async {
    return _addLayer(sourceId, layerId, properties, "circle",
        belowLayerId: belowLayerId,
        sourceLayer: sourceLayer,
        minzoom: minzoom,
        maxzoom: maxzoom,
        filter: filter,
        enableInteraction: enableInteraction);
  }

  @override
  Future<void> addFillLayer(
      String sourceId, String layerId, Map<String, dynamic> properties,
      {String? belowLayerId,
      String? sourceLayer,
      double? minzoom,
      double? maxzoom,
      dynamic filter,
      required bool enableInteraction}) async {
    return _addLayer(sourceId, layerId, properties, "fill",
        belowLayerId: belowLayerId,
        sourceLayer: sourceLayer,
        minzoom: minzoom,
        maxzoom: maxzoom,
        filter: filter,
        enableInteraction: enableInteraction);
  }

  @override
  Future<void> addFillExtrusionLayer(
      String sourceId, String layerId, Map<String, dynamic> properties,
      {String? belowLayerId,
      String? sourceLayer,
      double? minzoom,
      double? maxzoom,
      dynamic filter,
      required bool enableInteraction}) async {
    return _addLayer(sourceId, layerId, properties, "fill-extrusion",
        belowLayerId: belowLayerId,
        sourceLayer: sourceLayer,
        minzoom: minzoom,
        maxzoom: maxzoom,
        filter: filter,
        enableInteraction: enableInteraction);
  }

  @override
  Future<void> addLineLayer(
      String sourceId, String layerId, Map<String, dynamic> properties,
      {String? belowLayerId,
      String? sourceLayer,
      double? minzoom,
      double? maxzoom,
      dynamic filter,
      required bool enableInteraction}) async {
    return _addLayer(sourceId, layerId, properties, "line",
        belowLayerId: belowLayerId,
        sourceLayer: sourceLayer,
        minzoom: minzoom,
        maxzoom: maxzoom,
        filter: filter,
        enableInteraction: enableInteraction);
  }

  @override
  Future<void> addSymbolLayer(
      String sourceId, String layerId, Map<String, dynamic> properties,
      {String? belowLayerId,
      String? sourceLayer,
      double? minzoom,
      double? maxzoom,
      dynamic filter,
      required bool enableInteraction}) async {
    return _addLayer(sourceId, layerId, properties, "symbol",
        belowLayerId: belowLayerId,
        sourceLayer: sourceLayer,
        minzoom: minzoom,
        maxzoom: maxzoom,
        filter: filter,
        enableInteraction: enableInteraction);
  }

  @override
  Future<void> addHillshadeLayer(
      String sourceId, String layerId, Map<String, dynamic> properties,
      {String? belowLayerId,
      String? sourceLayer,
      double? minzoom,
      double? maxzoom}) async {
    return _addLayer(sourceId, layerId, properties, "hillshade",
        belowLayerId: belowLayerId,
        sourceLayer: sourceLayer,
        minzoom: minzoom,
        maxzoom: maxzoom,
        enableInteraction: false);
  }

  @override
  Future<void> addHeatmapLayer(
      String sourceId, String layerId, Map<String, dynamic> properties,
      {String? belowLayerId,
      String? sourceLayer,
      double? minzoom,
      double? maxzoom}) async {
    return _addLayer(sourceId, layerId, properties, "heatmap",
        belowLayerId: belowLayerId,
        sourceLayer: sourceLayer,
        minzoom: minzoom,
        maxzoom: maxzoom,
        enableInteraction: false);
  }

  @override
  Future<void> addRasterLayer(
      String sourceId, String layerId, Map<String, dynamic> properties,
      {String? belowLayerId,
      String? sourceLayer,
      double? minzoom,
      double? maxzoom}) async {
    await _addLayer(sourceId, layerId, properties, "raster",
        belowLayerId: belowLayerId,
        sourceLayer: sourceLayer,
        minzoom: minzoom,
        maxzoom: maxzoom,
        enableInteraction: false);
  }

  Future<void> _addLayer(String sourceId, String layerId,
      Map<String, dynamic> properties, String layerType,
      {String? belowLayerId,
      String? sourceLayer,
      double? minzoom,
      double? maxzoom,
      dynamic filter,
      required bool enableInteraction}) async {
    // Filter out null values to avoid Mapbox style validation warnings
    final layout = Map.fromEntries(properties.entries
        .where((entry) => isLayoutProperty(entry.key) && entry.value != null));
    final paint = Map.fromEntries(properties.entries
        .where((entry) => !isLayoutProperty(entry.key) && entry.value != null));

    removeLayer(layerId);

    _map.addLayer({
      'id': layerId,
      'type': layerType,
      'source': sourceId,
      if (layout.isNotEmpty) 'layout': layout,
      if (paint.isNotEmpty) 'paint': paint,
      if (sourceLayer != null) 'source-layer': sourceLayer,
      if (minzoom != null) 'minzoom': minzoom,
      if (maxzoom != null) 'maxzoom': maxzoom,
      if (filter != null) 'filter': filter,
    }, belowLayerId);

    if (enableInteraction) {
      _interactiveFeatureLayerIds.add(layerId);
      // Convert layerId to JSValue for WASM compatibility
      final jsLayerId = layerId.toJS;
      if (layerType == "fill") {
        _map.on('mousemove', jsLayerId, _onMouseEnterFeature);
      } else {
        _map.on('mouseenter', jsLayerId, _onMouseEnterFeature);
      }
      _map.on('mouseleave', jsLayerId, _onMouseLeaveFeature);
      if (_dragEnabled) _map.on('mousedown', jsLayerId, _onMouseDown);
    }
  }

  void _onMouseEnterFeature(_) {
    if (_draggedFeatureId == null) {
      _map.getCanvas().style.cursor = 'pointer';
    }
  }

  void _onMouseLeaveFeature(_) {
    _map.getCanvas().style.cursor = '';
  }

  @override
  void setGestures(
      {required bool rotateGesturesEnabled,
      required bool scrollGesturesEnabled,
      required bool tiltGesturesEnabled,
      required bool zoomGesturesEnabled,
      required bool doubleClickZoomEnabled}) {
    if (rotateGesturesEnabled &&
        scrollGesturesEnabled &&
        tiltGesturesEnabled &&
        zoomGesturesEnabled) {
      _map.keyboard.enable();
    } else {
      _map.keyboard.disable();
    }

    if (scrollGesturesEnabled) {
      _map.dragPan.enable();
    } else {
      _map.dragPan.disable();
    }

    if (zoomGesturesEnabled) {
      _map.doubleClickZoom.enable();
      _map.boxZoom.enable();
      _map.scrollZoom.enable();
      _map.touchZoomRotate.enable();
    } else {
      _map.doubleClickZoom.disable();
      _map.boxZoom.disable();
      _map.scrollZoom.disable();
      _map.touchZoomRotate.disable();
    }

    if (doubleClickZoomEnabled) {
      _map.doubleClickZoom.enable();
    } else {
      _map.doubleClickZoom.disable();
    }

    if (rotateGesturesEnabled) {
      _map.touchZoomRotate.enableRotation();
    } else {
      _map.touchZoomRotate.disableRotation();
    }

    // dragRotate is shared by both gestures
    if (tiltGesturesEnabled && rotateGesturesEnabled) {
      _map.dragRotate.enable();
    } else {
      _map.dragRotate.disable();
    }
  }

  @override
  Future<void> addSource(String sourceId, SourceProperties source) async {
    _map.addSource(sourceId, source.toJson());
  }

  Future<void> addImageSource(
      String imageSourceId, Uint8List bytes, LatLngQuad coordinates) {
    // TODO: implement addImageSource
    throw UnimplementedError();
  }

  Future<void> updateImageSource(
      String imageSourceId, Uint8List? bytes, LatLngQuad? coordinates) {
    // TODO: implement addImageSource
    throw UnimplementedError();
  }

  @override
  Future<void> addLayer(String imageLayerId, String imageSourceId,
      double? minzoom, double? maxzoom) {
    // TODO: implement addLayer
    throw UnimplementedError();
  }

  @override
  Future<void> addLayerBelow(String imageLayerId, String imageSourceId,
      String belowLayerId, double? minzoom, double? maxzoom) {
    // TODO: implement addLayerBelow
    throw UnimplementedError();
  }

  @override
  Future<void> updateContentInsets(EdgeInsets insets, bool animated) {
    // TODO: implement updateContentInsets
    throw UnimplementedError();
  }

  @override
  Future<void> setFeatureForGeoJsonSource(
      String sourceId, Map<String, dynamic> geojsonFeature) async {
    final source = _map.getSource(sourceId) as GeoJsonSource?;
    final data = _addedFeaturesByLayer[sourceId];

    if (source != null && data != null) {
      final feature = _makeFeature(geojsonFeature);
      final features = data.features.toList();
      final index = features.indexWhere((f) => f.id == feature.id);
      if (index >= 0) {
        features[index] = feature;
        final newData = FeatureCollection(features: features);
        _addedFeaturesByLayer[sourceId] = newData;

        source.setData(newData);
      }
    }
  }

  @override
  Future<String> takeSnapshot(SnapshotOptions snapshotOptions) async {
    if (snapshotOptions.styleUri != null || snapshotOptions.styleJson != null) {
      throw UnsupportedError("style option is not supported");
    }
    if (snapshotOptions.bounds != null) {
      throw UnsupportedError("bounds option is not supported");
    }
    if (snapshotOptions.centerCoordinate != null ||
        snapshotOptions.zoomLevel != null ||
        snapshotOptions.pitch != 0 ||
        snapshotOptions.heading != 0) {
      throw UnsupportedError("camera posision option is not supported");
    }
    final base64String = await _map.getCanvas().toDataUrl('image/jpeg');
    return base64String;
  }

  @override
  void resizeWebMap() {
    _onMapResize();
  }

  @override
  void forceResizeWebMap() {
    _map.resize();
  }
}
