import 'dart:js_interop';
import 'package:flutter/foundation.dart';

@JS('navigator.wakeLock.request')
external JSPromise _requestWakeLock(JSString type);

@JS()
@staticInterop
class WakeLockSentinel {}

extension WakeLockSentinelExtension on WakeLockSentinel {
  external JSPromise release();
}

WakeLockSentinel? _sentinel;

Future<void> requestWebWakeLock() async {
  try {
    final promise = _requestWakeLock('screen'.toJS);
    final sentinelAny = await promise.toDart;
    _sentinel = sentinelAny as WakeLockSentinel?;
    debugPrint('[WakeLock Web] screen wake lock acquired');
  } catch (e) {
    debugPrint('[WakeLock Web] wake lock not supported or failed: $e');
  }
}

Future<void> releaseWebWakeLock() async {
  try {
    if (_sentinel != null) {
      await _sentinel!.release().toDart;
      _sentinel = null;
      debugPrint('[WakeLock Web] screen wake lock released');
    }
  } catch (e) {
    debugPrint('[WakeLock Web] release wake lock error: $e');
  }
}
