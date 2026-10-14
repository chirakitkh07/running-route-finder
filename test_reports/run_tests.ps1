# รัน unit test แล้วบันทึกผลไว้ใน test_reports/results/<วันที่_เวลา>/
#   powershell -ExecutionPolicy Bypass -File test_reports\run_tests.ps1
#   powershell -ExecutionPolicy Bypass -File test_reports\run_tests.ps1 test\safety_scoring_test.dart
param([string[]]$Targets = @("test"))

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$stamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$out = Join-Path $PSScriptRoot "results\$stamp"
New-Item -ItemType Directory -Force $out | Out-Null

Write-Host "== flutter test $Targets  ->  $out" -ForegroundColor Cyan
$lines = & flutter test @Targets --reporter expanded --file-reporter "json:$out\results.json" 2>&1
$code = $LASTEXITCODE
$lines | ForEach-Object { "$_" } | Tee-Object -Variable console | Write-Host
$console | Out-File -Encoding utf8 "$out\console.txt"

(& flutter --version 2>&1 | Select-Object -First 1) | Out-File -Encoding utf8 "$out\flutter_version.txt"

& dart run tool/test_report.dart "$out\results.json" "$out"

if ($code -eq 0) {
    Write-Host "ผลรวม: ผ่านทั้งหมด" -ForegroundColor Green
} else {
    Write-Host "ผลรวม: มีข้อไม่ผ่าน (exit $code) ดู $out\summary.md" -ForegroundColor Red
}
exit $code
