import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:demo20426/services/api_service.dart';
import 'package:demo20426/services/safety_dijkstra_service.dart';

void main() {
  group('Safety Score Deduction Rules', () {
    test('Traffic congestion deduction (<=10% = 0, 10-30% = 5, >30% = 10)', () {
      expect(ApiService.trafficDeduction(0.0), equals(0));
      expect(ApiService.trafficDeduction(10.0), equals(0));
      expect(ApiService.trafficDeduction(15.0), equals(5));
      expect(ApiService.trafficDeduction(30.0), equals(5));
      expect(ApiService.trafficDeduction(35.0), equals(10));
      expect(ApiService.trafficDeduction(80.0), equals(10));
    });

    test('Traffic light deduction (0-1 = 0, 2-3 = 5, >=4 = 10)', () {
      expect(ApiService.trafficLightDeduction(0), equals(0));
      expect(ApiService.trafficLightDeduction(1), equals(0));
      expect(ApiService.trafficLightDeduction(2), equals(5));
      expect(ApiService.trafficLightDeduction(3), equals(5));
      expect(ApiService.trafficLightDeduction(4), equals(10));
      expect(ApiService.trafficLightDeduction(6), equals(10));
    });
  });

  group('Safety Dijkstra Algorithm with Traffic and Light penalties', () {
    test('Calculates path and penalizes congested segments and traffic lights', () {
      final path = [
        const LatLng(13.7500, 100.5000),
        const LatLng(13.7510, 100.5000),
        const LatLng(13.7520, 100.5000),
        const LatLng(13.7530, 100.5000),
      ];

      // Segment between 13.7510 and 13.7520 has traffic congestion
      final trafficSegments = [
        [const LatLng(13.7510, 100.5000), const LatLng(13.7520, 100.5000)],
      ];

      // Node at 13.7520 has traffic light
      final trafficLightNodes = [
        const LatLng(13.7520, 100.5000),
      ];

      final result = SafetyDijkstraService.run(
        osrmPath: path,
        incidents: [],
        trafficSegments: trafficSegments,
        trafficLightNodes: trafficLightNodes,
      );

      expect(result.path.isNotEmpty, isTrue);
      expect(result.edgeWeights.length, equals(3));
      // Edge 1 (between 13.7510 and 13.7520) should have risk added for traffic & light
      expect(result.edgeWeights[1], greaterThan(0));
    });
  });
}
