"""แปลง build/route_check/popular_paths.json (ผลจาก flutter test tool/route_check_test.dart)
เป็น lib/models/popular_route_paths.dart — ลดจุดด้วย Douglas–Peucker 1 ม.
รัน: python tool/embed_popular_paths.py"""
import json, math

def xy(p, lat0): return (p[1] * 111320.0 * math.cos(math.radians(lat0)), p[0] * 111320.0)
def dist(a, b):
    ax, ay = xy(a, a[0]); bx, by = xy(b, a[0]); return math.hypot(bx - ax, by - ay)
def plen(p): return sum(dist(p[i], p[i + 1]) for i in range(len(p) - 1))
def seg_dist(p, a, b):
    px, py = xy(p, a[0]); ax, ay = xy(a, a[0]); bx, by = xy(b, a[0])
    dx, dy = bx - ax, by - ay; l2 = dx * dx + dy * dy
    t = 0 if l2 == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / l2))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)
def dp(pts, tol):
    if len(pts) < 3: return pts
    keep = [False] * len(pts); keep[0] = keep[-1] = True
    st = [(0, len(pts) - 1)]
    while st:
        a, b = st.pop(); md, mi = 0, -1
        for i in range(a + 1, b):
            x = seg_dist(pts[i], pts[a], pts[b])
            if x > md: md, mi = x, i
        if md > tol: keep[mi] = True; st += [(a, mi), (mi, b)]
    return [p for p, k in zip(pts, keep) if k]
def simp(pts, closed):
    if not closed: return dp(pts, 1.0)
    h = len(pts) // 2
    return dp(pts[:h + 1], 1.0) + dp(pts[h:], 1.0)[1:]

d = json.load(open('build/route_check/popular_paths.json', encoding='utf-8'))
m = [('moatLoop', 'zone_moat', True), ('buakHad', 'zone_buakhad', True), ('huayTuengThao', 'zone_huaytueng', True),
     ('cmuCampus', 'zone_cmu', True), ('stadium700', 'zone_700yr', True), ('doiSuthep', 'doi_suthep_route', False)]
out = ["// GENERATED — อย่าแก้ด้วยมือ",
       "// path ของเส้นทางยอดนิยม สร้างจาก Routing API (OSRM เดินเท้า FOSSGIS) ด้วย RoutingService.zoneCourse",
       "// จึงอยู่บนถนน/ทางเดินจริงใน OSM ทุกช่วง — สร้างใหม่: flutter test tool/route_check_test.dart",
       "// แล้วรัน python tool/embed_popular_paths.py (ลดจุดด้วย Douglas–Peucker 1 ม.)",
       "import 'package:latlong2/latlong.dart';", "",
       "List<LatLng> _p(List<double> c) => [for (int i = 0; i < c.length; i += 2) LatLng(c[i], c[i + 1])];", "",
       "class PopularRoutePaths {"]
for name, key, closed in m:
    pts = simp([tuple(p) for p in d[key]], closed)
    print(f"{name}: {len(d[key])} -> {len(pts)} จุด, {plen(pts) / 1000:.2f} กม.")
    out.append(f"  /// {key} — {plen(pts) / 1000:.2f} กม.{' (วงปิด)' if closed else ' (ทางเดียว)'}")
    out.append(f"  static final List<LatLng> {name} = _p(const [")
    for i in range(0, len(pts), 4):
        out.append("    " + ", ".join(f"{p[0]:.6f}, {p[1]:.6f}" for p in pts[i:i + 4]) + ",")
    out.append("  ]);"); out.append("")
out[-1] = "}"
open('lib/models/popular_route_paths.dart', 'w', encoding='utf-8', newline='\n').write("\n".join(out) + "\n")
