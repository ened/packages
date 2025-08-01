// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:math' show Point;

import 'package:async/async.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart'
    show DeviceOrientation, PlatformException;
import 'package:flutter/widgets.dart' show Texture, Widget, visibleForTesting;
import 'package:stream_transform/stream_transform.dart';
import 'camerax_library.dart';
import 'camerax_proxy.dart';
import 'rotated_preview_delegate.dart';

/// The Android implementation of [CameraPlatform] that uses the CameraX library.
class AndroidCameraCameraX extends CameraPlatform {
  /// Constructs an [AndroidCameraCameraX].
  AndroidCameraCameraX();

  /// Registers this class as the default instance of [CameraPlatform].
  static void registerWith() {
    CameraPlatform.instance = AndroidCameraCameraX();
  }

  /// Proxy for creating `JavaObject`s and calling their methods that require
  /// testing.
  @visibleForTesting
  CameraXProxy proxy = CameraXProxy();

  /// The [ProcessCameraProvider] instance used to access camera functionality.
  @visibleForTesting
  ProcessCameraProvider? processCameraProvider;

  /// The [Camera] instance returned by the [processCameraProvider] when a [UseCase] is
  /// bound to the lifecycle of the camera it manages.
  @visibleForTesting
  Camera? camera;

  /// The [CameraInfo] instance that corresponds to the [camera] instance.
  @visibleForTesting
  CameraInfo? cameraInfo;

  /// The [CameraControl] instance that corresponds to the [camera] instance.
  late CameraControl cameraControl;

  /// The [LiveData] of the [CameraState] that represents the state of the
  /// [camera] instance.
  LiveData<CameraState>? liveCameraState;

  /// The [Preview] instance that can be configured to present a live camera preview.
  @visibleForTesting
  Preview? preview;

  /// The [VideoCapture] instance that can be instantiated and configured to
  /// handle video recording
  @visibleForTesting
  VideoCapture? videoCapture;

  /// The [Recorder] instance handling the current creating a new [PendingRecording].
  @visibleForTesting
  Recorder? recorder;

  /// The [PendingRecording] instance used to create an active [Recording].
  @visibleForTesting
  PendingRecording? pendingRecording;

  /// The [Recording] instance representing the current recording.
  @visibleForTesting
  Recording? recording;

  /// The path at which the video file will be saved for the current [Recording].
  @visibleForTesting
  String? videoOutputPath;

  /// Handles access to system resources.
  late final SystemServicesManager systemServicesManager = proxy
      .newSystemServicesManager(
        onCameraError: (_, String errorDescription) {
          cameraErrorStreamController.add(errorDescription);
        },
      );

  /// Handles retrieving media orientation for a device.
  late final DeviceOrientationManager deviceOrientationManager = proxy
      .newDeviceOrientationManager(
        onDeviceOrientationChanged: (_, String orientation) {
          final DeviceOrientation deviceOrientation =
              _deserializeDeviceOrientation(orientation);
          deviceOrientationChangedStreamController.add(
            DeviceOrientationChangedEvent(deviceOrientation),
          );
        },
      );

  /// Stream that emits an event when the corresponding video recording is finalized.
  static final StreamController<VideoRecordEvent>
  videoRecordingEventStreamController =
      StreamController<VideoRecordEvent>.broadcast();

  /// Stream that emits the errors caused by camera usage on the native side.
  static final StreamController<String> cameraErrorStreamController =
      StreamController<String>.broadcast();

  /// Stream that emits the device orientation whenever it is changed.
  ///
  /// Values may start being added to the stream once
  /// `startListeningForDeviceOrientationChange(...)` is called.
  static final StreamController<DeviceOrientationChangedEvent>
  deviceOrientationChangedStreamController =
      StreamController<DeviceOrientationChangedEvent>.broadcast();

  /// Stream queue to pick up finalized viceo recording events in
  /// [stopVideoRecording].
  final StreamQueue<VideoRecordEvent> videoRecordingEventStreamQueue =
      StreamQueue<VideoRecordEvent>(videoRecordingEventStreamController.stream);

  late final VideoRecordEventListener _videoRecordingEventListener = proxy
      .newVideoRecordEventListener(
        onEvent: (_, VideoRecordEvent event) {
          videoRecordingEventStreamController.add(event);
        },
      );

  /// Whether or not [preview] has been bound to the lifecycle of the camera by
  /// [createCamera].
  @visibleForTesting
  bool previewInitiallyBound = false;

  bool _previewIsPaused = false;

  /// The prefix used to create the filename for video recording files.
  @visibleForTesting
  final String videoPrefix = 'REC';

  /// The [ImageCapture] instance that can be configured to capture a still image.
  @visibleForTesting
  ImageCapture? imageCapture;

  /// The flash mode currently configured for [imageCapture].
  CameraXFlashMode? _currentFlashMode;

  /// Whether or not torch flash mode has been enabled for the [camera].
  @visibleForTesting
  bool torchEnabled = false;

  /// The [ImageAnalysis] instance that can be configured to analyze individual
  /// frames.
  ImageAnalysis? imageAnalysis;

  /// The [CameraSelector] used to configure the [processCameraProvider] to use
  /// the desired camera.
  @visibleForTesting
  CameraSelector? cameraSelector;

  /// The controller we need to broadcast the different camera events.
  ///
  /// It is a `broadcast` because multiple controllers will connect to
  /// different stream views of this Controller.
  /// This is only exposed for test purposes. It shouldn't be used by clients of
  /// the plugin as it may break or change at any time.
  @visibleForTesting
  final StreamController<CameraEvent> cameraEventStreamController =
      StreamController<CameraEvent>.broadcast();

  /// The stream of camera events.
  Stream<CameraEvent> _cameraEvents(int cameraId) => cameraEventStreamController
      .stream
      .where((CameraEvent event) => event.cameraId == cameraId);

  /// The controller we need to stream image data.
  @visibleForTesting
  StreamController<CameraImageData>? cameraImageDataStreamController;

  /// Constant representing the multi-plane Android YUV 420 image format.
  ///
  /// See https://developer.android.com/reference/android/graphics/ImageFormat#YUV_420_888.
  static const int imageFormatYuv420_888 = 35;

  /// Constant representing the compressed JPEG image format.
  ///
  /// See https://developer.android.com/reference/android/graphics/ImageFormat#JPEG.
  static const int imageFormatJpeg = 256;

  /// Error code indicating a [ZoomState] was requested, but one has not been
  /// set for the camera in use.
  static const String zoomStateNotSetErrorCode = 'zoomStateNotSet';

  /// Whether or not the capture orientation is locked.
  ///
  /// Indicates a new target rotation should not be set as it has been locked by
  /// [lockCaptureOrientation].
  @visibleForTesting
  bool captureOrientationLocked = false;

  /// Whether or not the default rotation for [UseCase]s needs to be set
  /// manually because the capture orientation was previously locked.
  ///
  /// Currently, CameraX provides no way to unset target rotations for
  /// [UseCase]s, so once they are set and unset, this plugin must start setting
  /// the default orientation manually.
  ///
  /// See https://developer.android.com/reference/androidx/camera/core/ImageCapture#setTargetRotation(int)
  /// for an example on how setting target rotations for [UseCase]s works.
  bool shouldSetDefaultRotation = false;

  /// Error code indicating that an exposure offset value failed to be set.
  static const String setExposureOffsetFailedErrorCode =
      'setExposureOffsetFailed';

  /// The currently set [FocusMeteringAction] used to enable auto-focus and
  /// auto-exposure.
  @visibleForTesting
  FocusMeteringAction? currentFocusMeteringAction;

  /// Current focus mode set via [setFocusMode].
  ///
  /// CameraX defaults to auto focus mode.
  FocusMode _currentFocusMode = FocusMode.auto;

  /// Current exposure mode set via [setExposureMode].
  ///
  /// CameraX defaults to auto exposure mode.
  ExposureMode _currentExposureMode = ExposureMode.auto;

  /// Whether or not a default focus point of the entire sensor area was focused
  /// and locked.
  ///
  /// This should only be true if [setExposureMode] was called to set
  /// [FocusMode.locked] and no previous focus point was set via
  /// [setFocusPoint].
  bool _defaultFocusPointLocked = false;

  /// Error code indicating that exposure compensation is not supported by
  /// CameraX for the device.
  static const String exposureCompensationNotSupported =
      'exposureCompensationNotSupported';

  /// Whether or not the created camera is front facing.
  @visibleForTesting
  late bool cameraIsFrontFacing;

  /// The camera sensor orientation.
  ///
  /// This can change if the camera being used changes. Also, it is independent
  /// of the device orientation or user interface orientation.
  @visibleForTesting
  late double sensorOrientationDegrees;

  /// Whether or not the Android surface producer automatically handles
  /// correcting the rotation of camera previews for the device this plugin runs on.
  late bool _handlesCropAndRotation;

  /// The initial orientation of the device when the camera is created.
  late DeviceOrientation _initialDeviceOrientation;

  /// The initial rotation of the Android default display when the camera is created.
  ///
  /// This is expressed in terms of one of the [Surface] rotation constant.
  late int _initialDefaultDisplayRotation;

  /// Whether or not audio should be enabled for recording video if permission is
  /// granted.
  @visibleForTesting
  late bool enableRecordingAudio;

  /// A map to associate a [CameraInfo] with its camera name.
  final Map<String, CameraInfo> _savedCameras = <String, CameraInfo>{};

  /// Returns list of all available cameras and their descriptions.
  @override
  Future<List<CameraDescription>> availableCameras() async {
    proxy.setUpGenericsProxy();

    final List<CameraDescription> cameraDescriptions = <CameraDescription>[];

    processCameraProvider ??= await proxy.getInstanceProcessCameraProvider();
    final List<CameraInfo> cameraInfos =
        (await processCameraProvider!.getAvailableCameraInfos()).cast();

    CameraLensDirection? cameraLensDirection;
    int cameraCount = 0;
    int? cameraSensorOrientation;
    String? cameraName;

    for (final CameraInfo cameraInfo in cameraInfos) {
      // Determine the lens direction by filtering the CameraInfo
      // TODO(gmackall): replace this with call to CameraInfo.getLensFacing when changes containing that method are available
      if ((await proxy
          .newCameraSelector(requireLensFacing: LensFacing.back)
          .filter(<CameraInfo>[cameraInfo])).isNotEmpty) {
        cameraLensDirection = CameraLensDirection.back;
      } else if ((await proxy
          .newCameraSelector(requireLensFacing: LensFacing.front)
          .filter(<CameraInfo>[cameraInfo])).isNotEmpty) {
        cameraLensDirection = CameraLensDirection.front;
      } else {
        //Skip this CameraInfo as its lens direction is unknown
        continue;
      }

      cameraSensorOrientation = cameraInfo.sensorRotationDegrees;
      cameraName = 'Camera $cameraCount';
      cameraCount++;

      _savedCameras[cameraName] = cameraInfo;

      // TODO(camsim99): Use camera ID retrieved from Camera2CameraInfo as
      // camera name: https://github.com/flutter/flutter/issues/147545.
      cameraDescriptions.add(
        CameraDescription(
          name: cameraName,
          lensDirection: cameraLensDirection,
          sensorOrientation: cameraSensorOrientation,
        ),
      );
    }

    return cameraDescriptions;
  }

  /// Creates an uninitialized camera instance with default settings and returns the camera ID.
  ///
  /// See [createCameraWithSettings]
  @override
  Future<int> createCamera(
    CameraDescription description,
    ResolutionPreset? resolutionPreset, {
    bool enableAudio = false,
  }) => createCameraWithSettings(
    description,
    MediaSettings(resolutionPreset: resolutionPreset, enableAudio: enableAudio),
  );

  /// Creates an uninitialized camera instance and returns the camera ID.
  ///
  /// In the CameraX library, cameras are accessed by combining [UseCase]s
  /// to an instance of a [ProcessCameraProvider]. Thus, to create an
  /// uninitialized camera instance, this method retrieves a
  /// [ProcessCameraProvider] instance.
  ///
  /// The specified `mediaSettings.resolutionPreset` is the target resolution
  /// that CameraX will attempt to select for the [UseCase]s constructed in this
  /// method ([preview], [imageCapture], [imageAnalysis], [videoCapture]). If
  /// unavailable, a fallback behavior of targeting the next highest resolution
  /// will be attempted. See https://developer.android.com/media/camera/camerax/configuration#specify-resolution.
  ///
  /// To return the camera ID, which is equivalent to the ID of the surface texture
  /// that a camera preview can be drawn to, a [Preview] instance is configured
  /// and bound to the [ProcessCameraProvider] instance.
  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings? mediaSettings,
  ) async {
    enableRecordingAudio = mediaSettings?.enableAudio ?? false;
    final CameraPermissionsError? error = await systemServicesManager
        .requestCameraPermissions(enableRecordingAudio);

    if (error != null) {
      throw CameraException(error.errorCode, error.description);
    }
    // Choose CameraInfo to create CameraSelector by name associated with desired camera.
    final CameraInfo? chosenCameraInfo = _savedCameras[cameraDescription.name];

    // Save CameraSelector that matches cameraDescription.
    final LensFacing cameraSelectorLensDirection =
        _getCameraSelectorLensDirection(cameraDescription.lensDirection);
    cameraIsFrontFacing = cameraSelectorLensDirection == LensFacing.front;
    cameraSelector = proxy.newCameraSelector(
      cameraInfoForFilter: chosenCameraInfo,
    );
    // Start listening for device orientation changes preceding camera creation.
    unawaited(
      deviceOrientationManager.startListeningForDeviceOrientationChange(),
    );
    // Determine ResolutionSelector and QualitySelector based on
    // resolutionPreset for camera UseCases.
    final ResolutionSelector? presetResolutionSelector =
        _getResolutionSelectorFromPreset(mediaSettings?.resolutionPreset);
    final QualitySelector? presetQualitySelector =
        _getQualitySelectorFromPreset(mediaSettings?.resolutionPreset);

    // Retrieve a fresh ProcessCameraProvider instance.
    processCameraProvider ??= await proxy.getInstanceProcessCameraProvider();
    unawaited(processCameraProvider!.unbindAll());

    // Configure Preview instance.
    preview = proxy.newPreview(
      resolutionSelector: presetResolutionSelector,
      /* use CameraX default target rotation */ targetRotation: null,
    );
    final int flutterSurfaceTextureId = await preview!.setSurfaceProvider(
      systemServicesManager,
    );

    // Configure ImageCapture instance.
    imageCapture = proxy.newImageCapture(
      resolutionSelector: presetResolutionSelector,
      /* use CameraX default target rotation */ targetRotation:
          await deviceOrientationManager.getDefaultDisplayRotation(),
    );

    // Configure ImageAnalysis instance.
    // Defaults to YUV_420_888 image format.
    imageAnalysis = proxy.newImageAnalysis(
      resolutionSelector: presetResolutionSelector,
      /* use CameraX default target rotation */ targetRotation: null,
    );

    // Configure VideoCapture and Recorder instances.
    recorder = proxy.newRecorder(qualitySelector: presetQualitySelector);
    videoCapture = proxy.withOutputVideoCapture(videoOutput: recorder!);

    // Bind configured UseCases to ProcessCameraProvider instance & mark Preview
    // instance as bound but not paused. Video capture is bound at first use
    // instead of here.
    camera = await processCameraProvider!.bindToLifecycle(
      cameraSelector!,
      <UseCase>[preview!, imageCapture!, imageAnalysis!],
    );
    await _updateCameraInfoAndLiveCameraState(flutterSurfaceTextureId);
    previewInitiallyBound = true;
    _previewIsPaused = false;

    // Retrieve info required for correcting the rotation of the camera preview
    // if necessary.

    final Camera2CameraInfo camera2CameraInfo = proxy.fromCamera2CameraInfo(
      cameraInfo: cameraInfo!,
    );
    sensorOrientationDegrees =
        ((await camera2CameraInfo.getCameraCharacteristic(
                  proxy.sensorOrientationCameraCharacteristics(),
                ))!
                as int)
            .toDouble();

    sensorOrientationDegrees = cameraDescription.sensorOrientation.toDouble();
    _handlesCropAndRotation =
        await preview!.surfaceProducerHandlesCropAndRotation();
    _initialDeviceOrientation = _deserializeDeviceOrientation(
      await deviceOrientationManager.getUiOrientation(),
    );
    _initialDefaultDisplayRotation =
        await deviceOrientationManager.getDefaultDisplayRotation();

    return flutterSurfaceTextureId;
  }

  /// Initializes the camera on the device.
  ///
  /// Since initialization of a camera does not directly map as an operation to
  /// the CameraX library, this method just retrieves information about the
  /// camera and sends a [CameraInitializedEvent].
  ///
  /// [imageFormatGroup] is used to specify the image format used for image
  /// streaming, but CameraX currently only supports YUV_420_888 (supported by
  /// Flutter) and RGBA (not supported by Flutter). CameraX uses YUV_420_888
  /// by default, so [imageFormatGroup] is not used.
  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    // Configure CameraInitializedEvent to send as representation of a
    // configured camera:
    // Retrieve preview resolution.
    if (preview == null) {
      // No camera has been created; createCamera must be called before initializeCamera.
      throw CameraException(
        'cameraNotFound',
        "Camera not found. Please call the 'create' method before calling 'initialize'",
      );
    }

    final ResolutionInfo previewResolutionInfo =
        (await preview!.getResolutionInfo())!;

    // Mark auto-focus, auto-exposure and setting points for focus & exposure
    // as available operations as CameraX does its best across devices to
    // support these by default.
    const ExposureMode exposureMode = ExposureMode.auto;
    const FocusMode focusMode = FocusMode.auto;
    const bool exposurePointSupported = true;
    const bool focusPointSupported = true;

    cameraEventStreamController.add(
      CameraInitializedEvent(
        cameraId,
        previewResolutionInfo.resolution.width.toDouble(),
        previewResolutionInfo.resolution.height.toDouble(),
        exposureMode,
        exposurePointSupported,
        focusMode,
        focusPointSupported,
      ),
    );
  }

  /// Releases the resources of the accessed camera.
  ///
  /// [cameraId] not used.
  @override
  Future<void> dispose(int cameraId) async {
    await preview?.releaseSurfaceProvider();
    await liveCameraState?.removeObservers();
    await processCameraProvider?.unbindAll();
    await imageAnalysis?.clearAnalyzer();
    await deviceOrientationManager.stopListeningForDeviceOrientationChange();
  }

  /// The camera has been initialized.
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) {
    return _cameraEvents(cameraId).whereType<CameraInitializedEvent>();
  }

  /// The camera's resolution has changed.
  ///
  /// This stream currently has no events being added to it from this plugin.
  @override
  Stream<CameraResolutionChangedEvent> onCameraResolutionChanged(int cameraId) {
    return _cameraEvents(cameraId).whereType<CameraResolutionChangedEvent>();
  }

  /// The camera started to close.
  @override
  Stream<CameraClosingEvent> onCameraClosing(int cameraId) {
    return _cameraEvents(cameraId).whereType<CameraClosingEvent>();
  }

  /// The camera experienced an error.
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) {
    return StreamGroup.mergeBroadcast<CameraErrorEvent>(
      <Stream<CameraErrorEvent>>[
        cameraErrorStreamController.stream.map<CameraErrorEvent>((
          String errorDescription,
        ) {
          return CameraErrorEvent(cameraId, errorDescription);
        }),
        _cameraEvents(cameraId).whereType<CameraErrorEvent>(),
      ],
    );
  }

  /// The camera finished recording a video.
  @override
  Stream<VideoRecordedEvent> onVideoRecordedEvent(int cameraId) {
    return _cameraEvents(cameraId).whereType<VideoRecordedEvent>();
  }

  /// Locks the capture orientation.
  @override
  Future<void> lockCaptureOrientation(
    int cameraId,
    DeviceOrientation orientation,
  ) async {
    // Flag that (1) default rotation for UseCases will need to be set manually
    // if orientation is ever unlocked and (2) the capture orientation is locked
    // and should not be changed until unlocked.
    shouldSetDefaultRotation = true;
    captureOrientationLocked = true;

    // Get target rotation based on locked orientation.
    final int targetLockedRotation = _getRotationConstantFromDeviceOrientation(
      orientation,
    );

    // Update UseCases to use target device orientation.
    await imageCapture!.setTargetRotation(targetLockedRotation);
    await imageAnalysis!.setTargetRotation(targetLockedRotation);
    await videoCapture!.setTargetRotation(targetLockedRotation);
  }

  /// Unlocks the capture orientation.
  @override
  Future<void> unlockCaptureOrientation(int cameraId) async {
    // Flag that default rotation should be set for UseCases as needed.
    captureOrientationLocked = false;
  }

  /// Sets the exposure point for automatically determining the exposure values.
  ///
  /// Supplying `null` for the [point] argument will result in resetting to the
  /// original exposure point value.
  ///
  /// Supplied non-null point must be mapped to the entire un-altered preview
  /// surface for the exposure point to be applied accurately.
  ///
  /// [cameraId] is not used.
  @override
  Future<void> setExposurePoint(int cameraId, Point<double>? point) async {
    // We lock the new focus and metering action if focus mode has been locked
    // to ensure that the current focus point remains locked. Any exposure mode
    // setting will not be impacted by this lock (setting an exposure mode
    // is implemented with Camera2 interop that will override settings to
    // achieve the expected exposure mode as needed).
    await _startFocusAndMeteringForPoint(
      point: point,
      meteringMode: MeteringMode.ae,
      disableAutoCancel: _currentFocusMode == FocusMode.locked,
    );
  }

  /// Gets the minimum supported exposure offset for the selected camera in EV units.
  ///
  /// [cameraId] not used.
  @override
  Future<double> getMinExposureOffset(int cameraId) async {
    final ExposureState exposureState = cameraInfo!.exposureState;
    return exposureState.exposureCompensationRange.lower *
        exposureState.exposureCompensationStep;
  }

  /// Gets the maximum supported exposure offset for the selected camera in EV units.
  ///
  /// [cameraId] not used.
  @override
  Future<double> getMaxExposureOffset(int cameraId) async {
    final ExposureState exposureState = cameraInfo!.exposureState;
    return exposureState.exposureCompensationRange.upper *
        exposureState.exposureCompensationStep;
  }

  /// Sets the focus mode for taking pictures.
  ///
  /// Setting [FocusMode.locked] will lock the current focus point if one exists
  /// or the center of entire sensor area if not, and will stay locked until
  /// either:
  ///   * Another focus point is set via [setFocusPoint] (which will then become
  ///     the locked focus point), or
  ///   * Locked focus mode is unset by setting [FocusMode.auto].
  @override
  Future<void> setFocusMode(int cameraId, FocusMode mode) async {
    if (_currentFocusMode == mode) {
      // Desired focus mode is already set.
      return;
    }

    MeteringPoint? autoFocusPoint;
    bool? disableAutoCancel;
    switch (mode) {
      case FocusMode.auto:
        // Determine auto-focus point to restore, if any. We do not restore
        // default auto-focus point if set previously to lock focus.
        final MeteringPoint? unLockedFocusPoint =
            _defaultFocusPointLocked
                ? null
                : currentFocusMeteringAction!.meteringPointsAf.first;
        _defaultFocusPointLocked = false;
        autoFocusPoint = unLockedFocusPoint;
        disableAutoCancel = false;
      case FocusMode.locked:
        MeteringPoint? lockedFocusPoint;

        // Determine if there is an auto-focus point set currently to lock.
        if (currentFocusMeteringAction != null) {
          final List<MeteringPoint> possibleCurrentAfPoints =
              currentFocusMeteringAction!.meteringPointsAf;
          lockedFocusPoint =
              possibleCurrentAfPoints.isEmpty
                  ? null
                  : possibleCurrentAfPoints.first;
        }

        // If there isn't, lock center of entire sensor area by default.
        if (lockedFocusPoint == null) {
          final DisplayOrientedMeteringPointFactory meteringPointFactory = proxy
              .newDisplayOrientedMeteringPointFactory(
                cameraInfo: cameraInfo!,
                width: 1,
                height: 1,
              );
          lockedFocusPoint = await meteringPointFactory.createPointWithSize(
            0.5,
            0.5,
            1,
          );
          _defaultFocusPointLocked = true;
        }

        autoFocusPoint = lockedFocusPoint;
        disableAutoCancel = true;
    }
    // Start appropriate focus and metering action.
    final bool focusAndMeteringWasSuccessful = await _startFocusAndMeteringFor(
      meteringPoint: autoFocusPoint,
      meteringMode: MeteringMode.af,
      disableAutoCancel: disableAutoCancel,
    );

    if (!focusAndMeteringWasSuccessful) {
      // Do not update current focus mode.
      return;
    }

    // Update current focus mode.
    _currentFocusMode = mode;

    // If focus mode was just locked and exposure mode is not, set auto exposure
    // mode to ensure that disabling auto-cancel does not interfere with
    // automatic exposure metering.
    if (_currentExposureMode == ExposureMode.auto &&
        _currentFocusMode == FocusMode.locked) {
      await setExposureMode(cameraId, _currentExposureMode);
    }
  }

  /// Gets the supported step size for exposure offset for the selected camera in EV units.
  ///
  /// Returns -1 if exposure compensation is not supported for the device.
  ///
  /// [cameraId] not used.
  @override
  Future<double> getExposureOffsetStepSize(int cameraId) async {
    final ExposureState exposureState = cameraInfo!.exposureState;
    final double exposureOffsetStepSize =
        exposureState.exposureCompensationStep;
    if (exposureOffsetStepSize == 0) {
      // CameraX returns a step size of 0 if exposure compensation is not
      // supported for the device.
      return -1;
    }
    return exposureOffsetStepSize;
  }

  /// Sets the exposure offset for the selected camera.
  ///
  /// The supplied [offset] value should be in EV units. 1 EV unit represents a
  /// doubling in brightness. It should be between the minimum and maximum offsets
  /// obtained through `getMinExposureOffset` and `getMaxExposureOffset` respectively.
  /// Throws a `CameraException` when trying to set exposure offset on a device
  /// that doesn't support exposure compensationan or if setting the offset fails,
  /// like in the case that an illegal offset is supplied.
  ///
  /// When the supplied [offset] value does not align with the step size obtained
  /// through `getExposureStepSize`, it will automatically be rounded to the nearest step.
  ///
  /// Returns the (rounded) offset value that was set.
  @override
  Future<double> setExposureOffset(int cameraId, double offset) async {
    final double exposureOffsetStepSize =
        cameraInfo!.exposureState.exposureCompensationStep;
    if (exposureOffsetStepSize == 0) {
      throw CameraException(
        exposureCompensationNotSupported,
        'Exposure compensation not supported',
      );
    }

    // (Exposure compensation index) * (exposure offset step size) =
    // (exposure offset).
    final int roundedExposureCompensationIndex =
        (offset / exposureOffsetStepSize).round();

    try {
      final int? newIndex = await cameraControl.setExposureCompensationIndex(
        roundedExposureCompensationIndex,
      );

      if (newIndex == null) {
        cameraErrorStreamController.add(
          'Setting exposure compensation index was canceled due to the camera being closed or a new request being submitted.',
        );
        throw CameraException(
          setExposureOffsetFailedErrorCode,
          'Setting exposure compensation index was canceled due to the camera being closed or a new request being submitted.',
        );
      }

      return newIndex.toDouble();
    } on PlatformException catch (e) {
      cameraErrorStreamController.add(
        e.message ?? 'Setting the camera exposure compensation index failed.',
      );
      // Surfacing error to plugin layer to maintain consistency of
      // setExposureOffset implementation across platform implementations.

      throw CameraException(
        setExposureOffsetFailedErrorCode,
        e.message ?? 'Setting the camera exposure compensation index failed.',
      );
    }
  }

  /// Sets the focus point for automatically determining the focus values.
  ///
  /// Supplying `null` for the [point] argument will result in resetting to the
  /// original focus point value.
  ///
  /// Supplied non-null point must be mapped to the entire un-altered preview
  /// surface for the focus point to be applied accurately.
  ///
  /// [cameraId] is not used.
  @override
  Future<void> setFocusPoint(int cameraId, Point<double>? point) async {
    // We lock the new focus and metering action if focus mode has been locked
    // to ensure that the current focus point remains locked. Any exposure mode
    // setting will not be impacted by this lock (setting an exposure mode
    // is implemented with Camera2 interop that will override settings to
    // achieve the expected exposure mode as needed).
    await _startFocusAndMeteringForPoint(
      point: point,
      meteringMode: MeteringMode.af,
      disableAutoCancel: _currentFocusMode == FocusMode.locked,
    );
  }

  /// Sets the exposure mode for taking pictures.
  ///
  /// Setting [ExposureMode.locked] will lock current exposure point until it
  /// is unset by setting [ExposureMode.auto].
  ///
  /// [cameraId] is not used.
  @override
  Future<void> setExposureMode(int cameraId, ExposureMode mode) async {
    final Camera2CameraControl camera2Control = proxy.fromCamera2CameraControl(
      cameraControl: cameraControl,
    );
    final bool lockExposureMode = mode == ExposureMode.locked;

    final CaptureRequestOptions captureRequestOptions = proxy
        .newCaptureRequestOptions(
          options: <CaptureRequestKey, Object?>{
            proxy.controlAELockCaptureRequest(): lockExposureMode,
          },
        );

    try {
      await camera2Control.addCaptureRequestOptions(captureRequestOptions);
    } on PlatformException catch (e) {
      cameraErrorStreamController.add(
        e.message ??
            'The camera was unable to set new capture request options due to new options being unavailable or the camera being closed.',
      );
    }

    _currentExposureMode = mode;
  }

  /// Gets the maximum supported zoom level for the selected camera.
  ///
  /// [cameraId] not used.
  @override
  Future<double> getMaxZoomLevel(int cameraId) async {
    final LiveData<ZoomState> liveZoomState = await cameraInfo!.getZoomState();
    final ZoomState? zoomState = await liveZoomState.getValue();

    if (zoomState == null) {
      throw CameraException(
        zoomStateNotSetErrorCode,
        'No explicit ZoomState has been set on the LiveData instance for the camera in use.',
      );
    }
    return zoomState.maxZoomRatio;
  }

  /// Gets the minimum supported zoom level for the selected camera.
  ///
  /// [cameraId] not used.
  @override
  Future<double> getMinZoomLevel(int cameraId) async {
    final LiveData<ZoomState> liveZoomState = await cameraInfo!.getZoomState();
    final ZoomState? zoomState = await liveZoomState.getValue();

    if (zoomState == null) {
      throw CameraException(
        zoomStateNotSetErrorCode,
        'No explicit ZoomState has been set on the LiveData instance for the camera in use.',
      );
    }
    return zoomState.minZoomRatio;
  }

  /// Set the zoom level for the selected camera.
  ///
  /// The supplied [zoom] value should be between the minimum and the maximum
  /// supported zoom level returned by [getMinZoomLevel] and [getMaxZoomLevel].
  /// Throws a `CameraException` when an illegal zoom level is supplied.
  @override
  Future<void> setZoomLevel(int cameraId, double zoom) async {
    try {
      await cameraControl.setZoomRatio(zoom);
    } on PlatformException catch (e) {
      cameraErrorStreamController.add(
        e.message ??
            'Zoom ratio was unable to be set. If ratio was not out of range, newer value may have been set; otherwise, the camera may be closed.',
      );
    }
  }

  /// The ui orientation changed.
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() {
    return deviceOrientationChangedStreamController.stream;
  }

  /// Pause the active preview on the current frame for the selected camera.
  ///
  /// [cameraId] not used.
  @override
  Future<void> pausePreview(int cameraId) async {
    _previewIsPaused = true;
    await _unbindUseCaseFromLifecycle(preview!);
  }

  /// Sets the active camera while recording.
  ///
  /// Currently unsupported, so is a no-op.
  @override
  Future<void> setDescriptionWhileRecording(CameraDescription description) {
    // TODO(camsim99): Implement this feature, see https://github.com/flutter/flutter/issues/148013.
    return Future<void>.value();
  }

  /// Resume the paused preview for the selected camera.
  ///
  /// [cameraId] not used.
  @override
  Future<void> resumePreview(int cameraId) async {
    _previewIsPaused = false;
    await _bindUseCaseToLifecycle(preview!, cameraId);
  }

  /// Returns a widget showing a live camera preview.
  ///
  /// [createCamera] must be called before attempting to build this preview.
  @override
  Widget buildPreview(int cameraId) {
    if (!previewInitiallyBound) {
      // No camera has been created, and thus, the preview UseCase has not been
      // bound to the camera lifecycle, restricting this preview from being
      // built.
      throw CameraException(
        'cameraNotFound',
        "Camera not found. Please call the 'create' method before calling 'buildPreview'",
      );
    }

    final Stream<DeviceOrientation> deviceOrientationStream =
        onDeviceOrientationChanged().map(
          (DeviceOrientationChangedEvent e) => e.orientation,
        );
    final Widget preview = Texture(textureId: cameraId);

    return RotatedPreviewDelegate(
      handlesCropAndRotation: _handlesCropAndRotation,
      initialDeviceOrientation: _initialDeviceOrientation,
      initialDefaultDisplayRotation: _initialDefaultDisplayRotation,
      deviceOrientationStream: deviceOrientationStream,
      sensorOrientationDegrees: sensorOrientationDegrees,
      cameraIsFrontFacing: cameraIsFrontFacing,
      deviceOrientationManager: deviceOrientationManager,
      child: preview,
    );
  }

  /// Captures an image and returns the file where it was saved.
  ///
  /// [cameraId] is not used.
  @override
  Future<XFile> takePicture(int cameraId) async {
    await _bindUseCaseToLifecycle(imageCapture!, cameraId);
    // Set flash mode.
    if (_currentFlashMode != null) {
      await imageCapture!.setFlashMode(_currentFlashMode!);
    } else if (torchEnabled) {
      // Ensure any previously set flash modes are unset when torch mode has
      // been enabled.
      await imageCapture!.setFlashMode(CameraXFlashMode.off);
    }

    // Set target rotation to the current default CameraX rotation if
    // the capture orientation is not locked.
    if (!captureOrientationLocked) {
      await imageCapture!.setTargetRotation(
        await deviceOrientationManager.getDefaultDisplayRotation(),
      );
    }

    final String picturePath = await imageCapture!.takePicture();
    return XFile(picturePath);
  }

  /// Sets the flash mode for the selected camera.
  ///
  /// When the [FlashMode.torch] is enabled, any previously set [FlashMode] with
  /// this method will be disabled, just as with any other [FlashMode]; while
  /// this is not default native Android behavior as defined by the CameraX API,
  /// this behavior is compliant with the plugin platform interface.
  ///
  /// This method combines the notion of setting the flash mode of the
  /// [imageCapture] UseCase and enabling the camera torch, as described
  /// by https://developer.android.com/reference/androidx/camera/core/ImageCapture
  /// and https://developer.android.com/reference/androidx/camera/core/CameraControl#enableTorch(boolean),
  /// respectively.
  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {
    // Turn off torch mode if it is enabled and not being redundantly set.
    if (mode != FlashMode.torch && torchEnabled) {
      await _enableTorchMode(false);
      torchEnabled = false;
    }

    switch (mode) {
      case FlashMode.off:
        _currentFlashMode = CameraXFlashMode.off;
      case FlashMode.auto:
        _currentFlashMode = CameraXFlashMode.auto;
      case FlashMode.always:
        _currentFlashMode = CameraXFlashMode.on;
      case FlashMode.torch:
        _currentFlashMode = null;
        if (torchEnabled) {
          // Torch mode enabled already.
          return;
        }

        await _enableTorchMode(true);
        torchEnabled = true;
    }
  }

  /// Prepare the capture session for video recording.
  ///
  /// This optimization is not used on Android, so this implementation is a
  /// no-op.
  @override
  Future<void> prepareForVideoRecording() {
    return Future<void>.value();
  }

  /// Configures and starts a video recording. Returns silently without doing
  /// anything if there is currently an active recording.
  ///
  /// Note that the preset resolution is used to configure the recording, but
  /// 240p ([ResolutionPreset.low]) is unsupported and will fallback to
  /// configure the recording as the next highest available quality.
  ///
  /// This method is deprecated in favour of [startVideoCapturing].
  @override
  Future<void> startVideoRecording(
    int cameraId, {
    Duration? maxVideoDuration,
  }) async {
    // Ignore maxVideoDuration, as it is unimplemented and deprecated.
    return startVideoCapturing(VideoCaptureOptions(cameraId));
  }

  /// Starts a video recording and/or streaming session.
  ///
  /// Please see [VideoCaptureOptions] for documentation on the
  /// configuration options. Currently streamOptions are unsupported due to
  /// limitations of the platform interface.
  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {
    if (recording != null) {
      // There is currently an active recording, so do not start a new one.
      return;
    }

    dynamic Function(CameraImageData)? streamCallback = options.streamCallback;
    if (!_previewIsPaused) {
      // The plugin binds the preview use case to the camera lifecycle when
      // createCamera is called, but camera use cases can become limited
      // when video recording and displaying a preview concurrently. This logic
      // will prioritize attempting to continue displaying the preview,
      // stream images, and record video if specified and supported. Otherwise,
      // the preview must be paused in order to allow those concurrently. See
      // https://developer.android.com/media/camera/camerax/architecture#combine-use-cases
      // for more information on supported concurrent camera use cases.
      final Camera2CameraInfo camera2CameraInfo = proxy.fromCamera2CameraInfo(
        cameraInfo: cameraInfo!,
      );
      final InfoSupportedHardwareLevel cameraInfoSupportedHardwareLevel =
          (await camera2CameraInfo.getCameraCharacteristic(
                proxy.infoSupportedHardwareLevelCameraCharacteristics(),
              ))!
              as InfoSupportedHardwareLevel;

      // Handle limited level device restrictions:
      final bool cameraSupportsConcurrentImageCapture =
          cameraInfoSupportedHardwareLevel != InfoSupportedHardwareLevel.legacy;
      if (!cameraSupportsConcurrentImageCapture) {
        // Concurrent preview + video recording + image capture is not supported
        // unless the camera device is cameraSupportsHardwareLevelLimited or
        // better.
        await _unbindUseCaseFromLifecycle(imageCapture!);
      }

      // Handle level 3 device restrictions:
      final bool cameraSupportsHardwareLevel3 =
          cameraInfoSupportedHardwareLevel == InfoSupportedHardwareLevel.level3;
      if (!cameraSupportsHardwareLevel3 || streamCallback == null) {
        // Concurrent preview + video recording + image streaming is not supported
        // unless the camera device is cameraSupportsHardwareLevel3 or better.
        streamCallback = null;
        await _unbindUseCaseFromLifecycle(imageAnalysis!);
      } else {
        // If image streaming concurrently with video recording, image capture
        // is unsupported.
        await _unbindUseCaseFromLifecycle(imageCapture!);
      }
    }

    await _bindUseCaseToLifecycle(videoCapture!, options.cameraId);

    // Set target rotation to default CameraX rotation only if capture
    // orientation not locked.
    if (!captureOrientationLocked && shouldSetDefaultRotation) {
      await videoCapture!.setTargetRotation(
        await deviceOrientationManager.getDefaultDisplayRotation(),
      );
    }

    videoOutputPath = await systemServicesManager.getTempFilePath(
      videoPrefix,
      '.temp',
    );
    pendingRecording = await recorder!.prepareRecording(videoOutputPath!);

    // Enable/disable recording audio as requested. If enabling audio is requested
    // and permission was not granted when the camera was created, then recording
    // audio will be disabled to respect the denied permission.
    pendingRecording = await pendingRecording!.withAudioEnabled(
      /* initialMuted */ !enableRecordingAudio,
    );

    recording = await pendingRecording!.start(_videoRecordingEventListener);

    if (streamCallback != null) {
      onStreamedFrameAvailable(options.cameraId).listen(streamCallback);
    }

    // Wait for video recording to start.
    VideoRecordEvent event = await videoRecordingEventStreamQueue.next;
    while (event is! VideoRecordEventStart) {
      event = await videoRecordingEventStreamQueue.next;
    }
  }

  /// Stops the video recording and returns the file where it was saved.
  /// Throws a CameraException if the recording is currently null, or if the
  /// videoOutputPath is null.
  ///
  /// If the videoOutputPath is null the recording objects are cleaned up
  /// so starting a new recording is possible.
  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    if (recording == null) {
      throw CameraException(
        'videoRecordingFailed',
        'Attempting to stop a '
            'video recording while no recording is in progress.',
      );
    }

    /// Stop the active recording and wait for the video recording to be finalized.
    await recording!.close();
    VideoRecordEvent event = await videoRecordingEventStreamQueue.next;
    while (event is! VideoRecordEventFinalize) {
      event = await videoRecordingEventStreamQueue.next;
    }
    recording = null;
    pendingRecording = null;

    if (videoOutputPath == null) {
      // Handle any errors with finalizing video recording.
      throw CameraException(
        'INVALID_PATH',
        'The platform did not return a path '
            'while reporting success. The platform should always '
            'return a valid path or report an error.',
      );
    }

    await _unbindUseCaseFromLifecycle(videoCapture!);
    final XFile videoFile = XFile(videoOutputPath!);
    cameraEventStreamController.add(
      VideoRecordedEvent(cameraId, videoFile, /* duration */ null),
    );
    return videoFile;
  }

  /// Pause the current video recording if it is not null.
  @override
  Future<void> pauseVideoRecording(int cameraId) async {
    if (recording != null) {
      await recording!.pause();
    }
  }

  /// Resume the current video recording if it is not null.
  @override
  Future<void> resumeVideoRecording(int cameraId) async {
    if (recording != null) {
      await recording!.resume();
    }
  }

  @override
  bool supportsImageStreaming() => true;

  /// A new streamed frame is available.
  ///
  /// Listening to this stream will start streaming, and canceling will stop.
  /// To temporarily stop receiving frames, cancel, then listen again later.
  /// Pausing/resuming is not supported, as pausing the stream would cause
  /// very high memory usage, and will throw an exception due to the
  /// implementation using a broadcast [StreamController], which does not
  /// support those operations.
  ///
  /// [cameraId] and [options] are not used.
  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) {
    cameraImageDataStreamController = StreamController<CameraImageData>(
      onListen: () async => _configureImageAnalysis(cameraId),
      onCancel: _onFrameStreamCancel,
    );
    return cameraImageDataStreamController!.stream;
  }

  // Methods for binding UseCases to the lifecycle of the camera controlled
  // by a ProcessCameraProvider instance:

  /// Binds [useCase] to the camera lifecycle controlled by the
  /// [processCameraProvider] if not already bound.
  ///
  /// [cameraId] used to build [CameraEvent]s should you wish to filter
  /// these based on a reference to a cameraId received from calling
  /// `createCamera(...)`.
  Future<void> _bindUseCaseToLifecycle(UseCase useCase, int cameraId) async {
    final bool useCaseIsBound = await processCameraProvider!.isBound(useCase);
    final bool useCaseIsPausedPreview = useCase is Preview && _previewIsPaused;

    if (useCaseIsBound || useCaseIsPausedPreview) {
      // Only bind if useCase is not already bound or preview is intentionally
      // paused.
      return;
    }

    camera = await processCameraProvider!.bindToLifecycle(
      cameraSelector!,
      <UseCase>[useCase],
    );

    await _updateCameraInfoAndLiveCameraState(cameraId);
  }

  /// Configures the [imageAnalysis] instance for image streaming.
  Future<void> _configureImageAnalysis(int cameraId) async {
    await _bindUseCaseToLifecycle(imageAnalysis!, cameraId);

    // Set target rotation to default CameraX rotation only if capture
    // orientation not locked.
    if (!captureOrientationLocked && shouldSetDefaultRotation) {
      await imageAnalysis!.setTargetRotation(
        await deviceOrientationManager.getDefaultDisplayRotation(),
      );
    }

    // Create and set Analyzer that can read image data for image streaming.
    final WeakReference<AndroidCameraCameraX> weakThis =
        WeakReference<AndroidCameraCameraX>(this);
    Future<void> analyze(ImageProxy imageProxy) async {
      final List<PlaneProxy> planes = await imageProxy.getPlanes();
      final List<CameraImagePlane> cameraImagePlanes = <CameraImagePlane>[];
      for (final PlaneProxy plane in planes) {
        cameraImagePlanes.add(
          CameraImagePlane(
            bytes: plane.buffer,
            bytesPerRow: plane.rowStride,
            bytesPerPixel: plane.pixelStride,
          ),
        );
      }

      final int format = imageProxy.format;
      final CameraImageFormat cameraImageFormat = CameraImageFormat(
        _imageFormatGroupFromPlatformData(format),
        raw: format,
      );

      final CameraImageData cameraImageData = CameraImageData(
        format: cameraImageFormat,
        planes: cameraImagePlanes,
        height: imageProxy.height,
        width: imageProxy.width,
      );

      weakThis.target!.cameraImageDataStreamController!.add(cameraImageData);
      await imageProxy.close();
    }

    await imageAnalysis!.setAnalyzer(
      proxy.newAnalyzer(analyze: (_, ImageProxy image) => analyze(image)),
    );
  }

  /// Unbinds [useCase] from camera lifecycle controlled by the
  /// [processCameraProvider] if not already unbound.
  Future<void> _unbindUseCaseFromLifecycle(UseCase useCase) async {
    final bool useCaseIsBound = await processCameraProvider!.isBound(useCase);
    if (!useCaseIsBound) {
      return;
    }

    await processCameraProvider!.unbind(<UseCase>[useCase]);
  }

  // Methods for configuring image streaming:

  /// The [onCancel] callback for the stream controller used for image
  /// streaming.
  ///
  /// Removes the previously set analyzer on the [imageAnalysis] instance, since
  /// image information should no longer be streamed.
  FutureOr<void> _onFrameStreamCancel() async {
    await imageAnalysis!.clearAnalyzer();
  }

  /// Converts between Android ImageFormat constants and [ImageFormatGroup]s.
  ///
  /// See https://developer.android.com/reference/android/graphics/ImageFormat.
  ImageFormatGroup _imageFormatGroupFromPlatformData(dynamic data) {
    switch (data) {
      case imageFormatYuv420_888: // android.graphics.ImageFormat.YUV_420_888
        return ImageFormatGroup.yuv420;
      case imageFormatJpeg: // android.graphics.ImageFormat.JPEG
        return ImageFormatGroup.jpeg;
    }

    return ImageFormatGroup.unknown;
  }

  // Methods concerning camera state:

  /// Updates [cameraInfo] and [cameraControl] to the information corresponding
  /// to [camera] and adds observers to the [LiveData] of the [CameraState] of
  /// the current [camera], saved as [liveCameraState].
  ///
  /// If a previous [liveCameraState] was stored, existing observers are
  /// removed, as well.
  Future<void> _updateCameraInfoAndLiveCameraState(int cameraId) async {
    cameraInfo = (await camera!.getCameraInfo()) as CameraInfo;
    cameraControl = camera!.cameraControl;
    await liveCameraState?.removeObservers();
    liveCameraState = await cameraInfo!.getCameraState();
    await liveCameraState!.observe(_createCameraClosingObserver(cameraId));
  }

  /// Creates [Observer] of the [CameraState] that will:
  ///
  ///  * Send a [CameraClosingEvent] if the [CameraState] indicates that the
  ///    camera has begun to close.
  ///  * Send a [CameraErrorEvent] if the [CameraState] indicates that the
  ///    camera is in error state.
  Observer<CameraState> _createCameraClosingObserver(int cameraId) {
    final WeakReference<AndroidCameraCameraX> weakThis =
        WeakReference<AndroidCameraCameraX>(this);

    // Callback method used to implement the behavior described above:
    void onChanged(CameraState state) {
      if (state.type == CameraStateType.closing) {
        weakThis.target!.cameraEventStreamController.add(
          CameraClosingEvent(cameraId),
        );
      }
      if (state.error != null) {
        late final String errorDescription;
        switch (state.error!.code) {
          case CameraStateErrorCode.cameraInUse:
            errorDescription =
                'The camera was already in use, possibly by a higher-priority camera client.';
          case CameraStateErrorCode.maxCamerasInUse:
            errorDescription =
                'The limit number of open cameras has been reached, and more cameras cannot be opened until other instances are closed.';
          case CameraStateErrorCode.otherRecoverableError:
            errorDescription =
                'The camera device has encountered a recoverable error. CameraX will attempt to recover from the error.';
          case CameraStateErrorCode.streamConfig:
            errorDescription = 'Configuring the camera has failed.';
          case CameraStateErrorCode.cameraDisabled:
            errorDescription =
                'The camera device could not be opened due to a device policy. Thia may be caused by a client from a background process attempting to open the camera.';
          case CameraStateErrorCode.cameraFatalError:
            errorDescription =
                'The camera was closed due to a fatal error. This may require the Android device be shut down and restarted to restore camera function or may indicate a persistent camera hardware problem.';
          case CameraStateErrorCode.doNotDisturbModeEnabled:
            errorDescription =
                'The camera could not be opened because "Do Not Disturb" mode is enabled. Please disable this mode, and try opening the camera again.';
          case CameraStateErrorCode.unknown:
            errorDescription =
                'There was an unspecified issue with the current camera state.';
        }
        weakThis.target!.cameraEventStreamController.add(
          CameraErrorEvent(cameraId, errorDescription),
        );
      }
    }

    return proxy.newObserver<CameraState>(
      onChanged: (_, CameraState value) => onChanged(value),
    );
  }

  // Methods for mapping Flutter camera constants to CameraX constants:

  /// Returns [CameraSelector] lens direction that maps to specified
  /// [CameraLensDirection].
  LensFacing _getCameraSelectorLensDirection(
    CameraLensDirection lensDirection,
  ) {
    switch (lensDirection) {
      case CameraLensDirection.front:
        return LensFacing.front;
      case CameraLensDirection.back:
        return LensFacing.back;
      case CameraLensDirection.external:
        return LensFacing.external;
    }
  }

  /// Returns [Surface] constant for counter-clockwise degrees of rotation from
  /// [DeviceOrientation.portraitUp] required to reach the specified
  /// [DeviceOrientation].
  int _getRotationConstantFromDeviceOrientation(DeviceOrientation orientation) {
    switch (orientation) {
      case DeviceOrientation.portraitUp:
        return Surface.rotation0;
      case DeviceOrientation.landscapeLeft:
        return Surface.rotation90;
      case DeviceOrientation.portraitDown:
        return Surface.rotation180;
      case DeviceOrientation.landscapeRight:
        return Surface.rotation270;
    }
  }

  /// Returns the [ResolutionSelector] that maps to the specified resolution
  /// preset for camera [UseCase]s.
  ///
  /// If the specified [preset] is unavailable, the camera will fall back to the
  /// closest lower resolution available.
  ResolutionSelector? _getResolutionSelectorFromPreset(
    ResolutionPreset? preset,
  ) {
    const ResolutionStrategyFallbackRule fallbackRule =
        ResolutionStrategyFallbackRule.closestLowerThenHigher;

    CameraSize? boundSize;
    AspectRatio? aspectRatio;
    ResolutionStrategy? resolutionStrategy;
    switch (preset) {
      case ResolutionPreset.low:
        boundSize = proxy.newCameraSize(width: 320, height: 240);
        aspectRatio = AspectRatio.ratio4To3;
      case ResolutionPreset.medium:
        boundSize = proxy.newCameraSize(width: 720, height: 480);
      case ResolutionPreset.high:
        boundSize = proxy.newCameraSize(width: 1280, height: 720);
        aspectRatio = AspectRatio.ratio16To9;
      case ResolutionPreset.veryHigh:
        boundSize = proxy.newCameraSize(width: 1920, height: 1080);
        aspectRatio = AspectRatio.ratio16To9;
      case ResolutionPreset.ultraHigh:
        boundSize = proxy.newCameraSize(width: 3840, height: 2160);
        aspectRatio = AspectRatio.ratio16To9;
      case ResolutionPreset.max:
        // Automatically set strategy to choose highest available.
        resolutionStrategy = proxy.highestAvailableStrategyResolutionStrategy();
        return proxy.newResolutionSelector(
          resolutionStrategy: resolutionStrategy,
        );
      case null:
        // If no preset is specified, default to CameraX's default behavior
        // for each UseCase.
        return null;
    }

    resolutionStrategy = proxy.newResolutionStrategy(
      boundSize: proxy.newCameraSize(
        width: boundSize.width,
        height: boundSize.height,
      ),
      fallbackRule: fallbackRule,
    );
    final ResolutionFilter resolutionFilter = proxy
        .createWithOnePreferredSizeResolutionFilter(preferredSize: boundSize);
    final AspectRatioStrategy? aspectRatioStrategy =
        aspectRatio == null
            ? null
            : proxy.newAspectRatioStrategy(
              preferredAspectRatio: aspectRatio,
              fallbackRule: AspectRatioStrategyFallbackRule.auto,
            );
    return proxy.newResolutionSelector(
      resolutionStrategy: resolutionStrategy,
      resolutionFilter: resolutionFilter,
      aspectRatioStrategy: aspectRatioStrategy,
    );
  }

  /// Returns the [QualitySelector] that maps to the specified resolution
  /// preset for the camera used only for video capture.
  ///
  /// If the specified [preset] is unavailable, the camera will fall back to the
  /// closest lower resolution available.
  QualitySelector? _getQualitySelectorFromPreset(ResolutionPreset? preset) {
    VideoQuality? videoQuality;
    switch (preset) {
      case ResolutionPreset.low:
      // 240p is not supported by CameraX.
      case ResolutionPreset.medium:
        videoQuality = VideoQuality.SD;
      case ResolutionPreset.high:
        videoQuality = VideoQuality.HD;
      case ResolutionPreset.veryHigh:
        videoQuality = VideoQuality.FHD;
      case ResolutionPreset.ultraHigh:
        videoQuality = VideoQuality.UHD;
      case ResolutionPreset.max:
        videoQuality = VideoQuality.highest;
      case null:
        // If no preset is specified, default to CameraX's default behavior
        // for each UseCase.
        return null;
    }

    // We will choose the next highest video quality if the one desired
    // is unavailable.
    final FallbackStrategy fallbackStrategy = proxy
        .lowerQualityOrHigherThanFallbackStrategy(quality: videoQuality);

    return proxy.fromQualitySelector(
      quality: videoQuality,
      fallbackStrategy: fallbackStrategy,
    );
  }

  // Methods for configuring auto-focus and auto-exposure:

  Future<bool> _startFocusAndMeteringForPoint({
    required Point<double>? point,
    required MeteringMode meteringMode,
    bool disableAutoCancel = false,
  }) async {
    MeteringPoint? meteringPoint;
    if (point != null) {
      if (point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1) {
        throw CameraException(
          'pointInvalid',
          'The coordinates of a metering point for an auto-focus or auto-exposure action must be within (0,0) and (1,1), but a point with coordinates (${point.x}, ${point.y}) was provided for metering mode $meteringMode.',
        );
      }

      final DisplayOrientedMeteringPointFactory meteringPointFactory = proxy
          .newDisplayOrientedMeteringPointFactory(
            width: 1.0,
            height: 1.0,
            cameraInfo: cameraInfo!,
          );
      meteringPoint = await meteringPointFactory.createPoint(point.x, point.y);
    }
    return _startFocusAndMeteringFor(
      meteringPoint: meteringPoint,
      meteringMode: meteringMode,
      disableAutoCancel: disableAutoCancel,
    );
  }

  /// Starts a focus and metering action and returns whether or not it was
  /// successful.
  ///
  /// This method will modify and start the current action's [MeteringPoint]s
  /// overriden with the [meteringPoint] provided for the specified
  /// [meteringMode] type only, with all other metering points of other modes
  /// left untouched. If no current action exists, only the specified
  /// [meteringPoint] will be set. Thus, the focus and metering action started
  /// will only contain at most the one most recently set metering point for
  /// each metering mode: AF, AE, AWB.
  ///
  /// Thus, if [meteringPoint] is non-null, this action includes:
  ///   * metering points and their modes previously added to
  ///     [currentFocusMeteringAction] that do not share a metering mode with
  ///     [meteringPoint] (if [currentFocusMeteringAction] is non-null) and
  ///   * [meteringPoint] with the specified [meteringMode].
  /// If [meteringPoint] is null and [currentFocusMeteringAction] is non-null,
  /// this action includes only metering points and their modes previously added
  /// to [currentFocusMeteringAction] that do not share a metering mode with
  /// [meteringPoint]. If [meteringPoint] and [currentFocusMeteringAction] are
  /// null, then focus and metering will be canceled.
  Future<bool> _startFocusAndMeteringFor({
    required MeteringPoint? meteringPoint,
    required MeteringMode meteringMode,
    bool disableAutoCancel = false,
  }) async {
    if (meteringPoint == null) {
      // Try to clear any metering point from previous action with the specified
      // meteringMode.
      if (currentFocusMeteringAction == null) {
        // Attempting to clear a metering point from a previous action, but no
        // such action exists.
        return false;
      }

      final Iterable<(MeteringPoint, MeteringMode)> originalMeteringPoints =
          _combineMeteringPoints(currentFocusMeteringAction!);

      // Remove metering point with specified meteringMode from current focus
      // and metering action, as only one focus or exposure point may be set
      // at once in this plugin.
      final List<(MeteringPoint, MeteringMode)> newMeteringPointInfos =
          originalMeteringPoints
              .where(
                ((MeteringPoint, MeteringMode) meteringPointInfo) =>
                    // meteringPointInfo may technically include points without a
                    // mode specified, but this logic is safe because this plugin
                    // only uses points that explicitly have mode
                    // FocusMeteringAction.flagAe or FocusMeteringAction.flagAf.
                    meteringPointInfo.$2 != meteringMode,
              )
              .toList();

      if (newMeteringPointInfos.isEmpty) {
        // If no other metering points were specified, cancel any previously
        // started focus and metering actions.
        await cameraControl.cancelFocusAndMetering();
        currentFocusMeteringAction = null;
        return true;
      }
      // Create builder to potentially add more MeteringPoints to.
      final FocusMeteringActionBuilder actionBuilder = proxy
          .withModeFocusMeteringActionBuilder(
            point: newMeteringPointInfos.first.$1,
            mode: newMeteringPointInfos.first.$2,
          );
      if (disableAutoCancel) {
        unawaited(actionBuilder.disableAutoCancel());
      }

      // Add any additional metering points in order as specified by input lists.
      newMeteringPointInfos.skip(1).forEach((
        (MeteringPoint point, MeteringMode) info,
      ) {
        actionBuilder.addPointWithMode(info.$1, info.$2);
      });
      currentFocusMeteringAction = await actionBuilder.build();
    } else {
      // Add new metering point with specified meteringMode, which may involve
      // replacing a metering point with the same specified meteringMode from
      // the current focus and metering action.
      List<(MeteringPoint, MeteringMode)> newMeteringPointInfos =
          <(MeteringPoint, MeteringMode)>[];

      if (currentFocusMeteringAction != null) {
        final Iterable<(MeteringPoint, MeteringMode)> originalMeteringPoints =
            _combineMeteringPoints(currentFocusMeteringAction!);

        newMeteringPointInfos =
            originalMeteringPoints
                .where(
                  ((MeteringPoint, MeteringMode) meteringPointInfo) =>
                      // meteringPointInfo may technically include points without a
                      // mode specified, but this logic is safe because this plugin
                      // only uses points that explicitly have mode
                      // FocusMeteringAction.flagAe or FocusMeteringAction.flagAf.
                      meteringPointInfo.$2 != meteringMode,
                )
                .toList();
      }

      newMeteringPointInfos.add((meteringPoint, meteringMode));

      final FocusMeteringActionBuilder actionBuilder = proxy
          .withModeFocusMeteringActionBuilder(
            point: newMeteringPointInfos.first.$1,
            mode: newMeteringPointInfos.first.$2,
          );

      if (disableAutoCancel) {
        unawaited(actionBuilder.disableAutoCancel());
      }

      newMeteringPointInfos.skip(1).forEach((
        (MeteringPoint point, MeteringMode mode) info,
      ) {
        actionBuilder.addPointWithMode(info.$1, info.$2);
      });
      currentFocusMeteringAction = await actionBuilder.build();
    }

    try {
      final FocusMeteringResult? result = await cameraControl
          .startFocusAndMetering(currentFocusMeteringAction!);

      if (result == null) {
        cameraErrorStreamController.add(
          'Starting focus and metering was canceled due to the camera being closed or a new request being submitted.',
        );
      }

      return result?.isFocusSuccessful ?? false;
    } on PlatformException catch (e) {
      cameraErrorStreamController.add(
        e.message ?? 'Starting focus and metering failed.',
      );
      // Surfacing error to differentiate an operation cancellation from an
      // illegal argument exception at a plugin layer.
      rethrow;
    }
  }

  // Combines the metering points and metering modes of a `FocusMeteringAction`
  // into a single list.
  Iterable<(MeteringPoint, MeteringMode)> _combineMeteringPoints(
    FocusMeteringAction focusMeteringAction,
  ) {
    Iterable<(MeteringPoint, MeteringMode)> toMeteringPointRecords(
      Iterable<MeteringPoint> points,
      MeteringMode mode,
    ) {
      return points.map((MeteringPoint point) => (point, mode));
    }

    return <(MeteringPoint, MeteringMode)>[
      ...toMeteringPointRecords(
        focusMeteringAction.meteringPointsAf,
        MeteringMode.af,
      ),
      ...toMeteringPointRecords(
        focusMeteringAction.meteringPointsAe,
        MeteringMode.ae,
      ),
      ...toMeteringPointRecords(
        focusMeteringAction.meteringPointsAwb,
        MeteringMode.awb,
      ),
    ];
  }

  Future<void> _enableTorchMode(bool value) async {
    try {
      await cameraControl.enableTorch(value);
    } on PlatformException catch (e) {
      cameraErrorStreamController.add(
        e.message ?? 'The camera was unable to change torch modes.',
      );
    }
  }

  static DeviceOrientation _deserializeDeviceOrientation(String orientation) {
    switch (orientation) {
      case 'LANDSCAPE_LEFT':
        return DeviceOrientation.landscapeLeft;
      case 'LANDSCAPE_RIGHT':
        return DeviceOrientation.landscapeRight;
      case 'PORTRAIT_DOWN':
        return DeviceOrientation.portraitDown;
      case 'PORTRAIT_UP':
        return DeviceOrientation.portraitUp;
      default:
        throw ArgumentError(
          '"$orientation" is not a valid DeviceOrientation value',
        );
    }
  }
}
