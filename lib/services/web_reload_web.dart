import 'dart:js_interop';

@JS('window.location.reload')
external void _locationReload();

@JS('navigator.serviceWorker.getRegistrations')
external JSPromise _getServiceWorkerRegistrations();

@JS()
@staticInterop
class ServiceWorkerRegistration {}

extension ServiceWorkerRegistrationExtension on ServiceWorkerRegistration {
  external JSPromise unregister();
}

Future<void> reloadWebPage() async {
  try {
    final promise = _getServiceWorkerRegistrations();
    final listAny = await promise.toDart;
    final jsArray = listAny as JSArray?;
    if (jsArray != null) {
      final length = jsArray.length;
      for (int i = 0; i < length; i++) {
        final reg = jsArray[i] as ServiceWorkerRegistration?;
        if (reg != null) {
          await reg.unregister().toDart;
        }
      }
    }
  } catch (_) {}

  _locationReload();
}
