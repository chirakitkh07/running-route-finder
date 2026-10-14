{{flutter_js}}
{{flutter_build_config}}

// ชื่อ main.dart.js ไม่เปลี่ยนตามเวอร์ชัน → ต่อ ?v=<hash ของ build> ให้ browser ไม่ใช้ไฟล์เก่าใน cache
var buildVersion = {{flutter_service_worker_version}};
(_flutter.buildConfig.builds || []).forEach(function (b) {
  if (b && b.mainJsPath) b.mainJsPath += '?v=' + buildVersion;
});

_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
});
