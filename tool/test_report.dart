// แปลงผล `flutter test --file-reporter json:<file>` เป็นรายงาน
//   summary.md  — ตารางสรุปผลแยกตามไฟล์ (ใช้แนบเล่ม / ตรวจเอง)
//   results.csv — ตารางเดียวกันสำหรับเปิดใน Excel (UTF-8 BOM)
//
// ใช้: dart run tool/test_report.dart <results.json> <outDir>
// ปกติเรียกผ่าน test_reports/run_tests.ps1
import 'dart:convert';
import 'dart:io';

class _Case {
  _Case(this.id, this.file, this.group, this.name, this.start);
  final int id;
  final String file;
  final String group;
  final String name;
  final int start;
  String result = 'running';
  bool skipped = false;
  int ms = 0;
  final errors = <String>[];
}

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/test_report.dart <results.json> <outDir>');
    exit(64);
  }
  final jsonFile = File(args[0]);
  final outDir = Directory(args[1])..createSync(recursive: true);
  final root = Directory.current.path.replaceAll('\\', '/');

  final suites = <int, String>{};
  final groups = <int, String>{};
  final cases = <int, _Case>{};
  var totalMs = 0;

  for (final line in jsonFile.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final Map<String, dynamic> e;
    try {
      e = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    switch (e['type']) {
      case 'suite':
        final s = e['suite'] as Map<String, dynamic>;
        var path = (s['path'] as String? ?? '').replaceAll('\\', '/');
        if (path.startsWith(root)) path = path.substring(root.length + 1);
        suites[s['id'] as int] = path;
      case 'group':
        final g = e['group'] as Map<String, dynamic>;
        groups[g['id'] as int] = g['name'] as String? ?? '';
      case 'testStart':
        final t = e['test'] as Map<String, dynamic>;
        final gids = (t['groupIDs'] as List).cast<int>();
        final group = gids.isEmpty ? '' : groups[gids.last] ?? '';
        var name = t['name'] as String;
        if (group.isNotEmpty && name.startsWith('$group ')) {
          name = name.substring(group.length + 1);
        }
        cases[t['id'] as int] = _Case(t['id'] as int,
            suites[t['suiteID']] ?? '?', group, name, e['time'] as int);
      case 'error':
        cases[e['testID']]?.errors.add('${e['error']}'.trim());
      case 'testDone':
        final c = cases[e['testID']];
        if (c == null) continue;
        if (e['hidden'] == true) {
          // "loading ..." ของแต่ละไฟล์ — เก็บไว้เฉพาะเมื่อโหลดไฟล์ไม่สำเร็จ
          if (e['result'] == 'success') {
            cases.remove(c.id);
            continue;
          }
        }
        c.result = e['result'] as String;
        c.skipped = e['skipped'] == true;
        c.ms = (e['time'] as int) - c.start;
      case 'done':
        totalMs = e['time'] as int? ?? 0;
    }
  }

  final all = cases.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  String status(_Case c) => c.skipped
      ? 'ข้าม'
      : c.result == 'success'
          ? 'ผ่าน'
          : 'ไม่ผ่าน';
  final pass = all.where((c) => status(c) == 'ผ่าน').length;
  final skip = all.where((c) => status(c) == 'ข้าม').length;
  final fail = all.length - pass - skip;
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}';
  String cell(String s) => s.replaceAll('|', '\\|').replaceAll('\n', ' ');

  final md = StringBuffer()
    ..writeln('# รายงานผลการทดสอบระดับหน่วย (Unit Test)')
    ..writeln()
    ..writeln('- วันที่รัน: $stamp')
    ..writeln('- ไฟล์ผลดิบ: `${jsonFile.uri.pathSegments.last}`')
    ..writeln('- เวลารวม: ${(totalMs / 1000).toStringAsFixed(1)} วินาที')
    ..writeln()
    ..writeln('| ทั้งหมด | ผ่าน | ไม่ผ่าน | ข้าม | อัตราผ่าน |')
    ..writeln('|---:|---:|---:|---:|---:|')
    ..writeln('| ${all.length} | $pass | $fail | $skip | '
        '${all.isEmpty ? '-' : '${(pass * 100 / all.length).toStringAsFixed(1)}%'} |')
    ..writeln()
    ..writeln('**ผลรวม: ${fail == 0 ? '✅ ผ่านทั้งหมด' : '❌ มี $fail ข้อไม่ผ่าน'}**')
    ..writeln();

  final byFile = <String, List<_Case>>{};
  for (final c in all) {
    byFile.putIfAbsent(c.file, () => []).add(c);
  }
  var no = 0;
  for (final entry in byFile.entries) {
    final p = entry.value.where((c) => status(c) == 'ผ่าน').length;
    md
      ..writeln('## `${entry.key}` ($p/${entry.value.length})')
      ..writeln()
      ..writeln('| ลำดับ | กลุ่ม | กรณีทดสอบ | ผล | เวลา (ms) |')
      ..writeln('|---:|---|---|:---:|---:|');
    for (final c in entry.value) {
      no++;
      final icon = {'ผ่าน': '✅', 'ไม่ผ่าน': '❌', 'ข้าม': '⏭️'}[status(c)];
      md.writeln('| $no | ${cell(c.group)} | ${cell(c.name)} | '
          '$icon ${status(c)} | ${c.ms} |');
    }
    md.writeln();
  }

  final failed = all.where((c) => status(c) == 'ไม่ผ่าน').toList();
  if (failed.isNotEmpty) {
    md
      ..writeln('## รายละเอียดข้อที่ไม่ผ่าน')
      ..writeln();
    for (final c in failed) {
      md
        ..writeln('### ${c.file} — ${c.group} ${c.name}')
        ..writeln()
        ..writeln('```')
        ..writeln(c.errors.join('\n\n'))
        ..writeln('```')
        ..writeln();
    }
  }
  File('${outDir.path}/summary.md').writeAsStringSync(md.toString());

  String csv(String s) => '"${s.replaceAll('"', '""')}"';
  final rows = StringBuffer('\uFEFFลำดับ,ไฟล์,กลุ่ม,กรณีทดสอบ,ผล,เวลา (ms)\r\n');
  for (var i = 0; i < all.length; i++) {
    final c = all[i];
    rows.write('${i + 1},${csv(c.file)},${csv(c.group)},${csv(c.name)},'
        '${status(c)},${c.ms}\r\n');
  }
  File('${outDir.path}/results.csv').writeAsStringSync(rows.toString());

  stdout.writeln('รายงาน: ${outDir.path}/summary.md  '
      '(ทั้งหมด ${all.length}, ผ่าน $pass, ไม่ผ่าน $fail, ข้าม $skip)');
}
