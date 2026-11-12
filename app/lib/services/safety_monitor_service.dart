import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';

class SafetyMonitorService {
  static final SafetyMonitorService _instance =
      SafetyMonitorService._internal();
  factory SafetyMonitorService() => _instance;
  SafetyMonitorService._internal();

  StreamSubscription<Position>? _positionStream;
  StreamSubscription<QuerySnapshot>? _zonesStream;

  String? _patientId;
  String? _lastStatus;

  List<Map<String, dynamic>> _safeZones = [];
  bool _isMonitoring = false;

  // ✅ [추가] GPS Drift 방지용 변수들
  static const int _maxRecentPositions = 5; // 최근 좌표 저장 개수
  static const double _maxAcceptableAccuracy =
      30.0; // 허용 최대 정확도(m) - 30m 이상이면 무시
  static const int _requiredConsecutiveOutside =
      2; // ✅ [수정] 연속 2회 이탈 시 비상 판단 (기존 3회 → 2회로 빠른 알림)
  static const double _driftStdDevThreshold =
      25.0; // 표준편차 임계값(m) - 이 이상이면 GPS가 튀고 있다고 판단

  final List<Position> _recentPositions = []; // 최근 좌표 버퍼
  int _consecutiveOutsideCount = 0; // 연속 이탈 카운터
  int _consecutiveInsideCount = 0; // 연속 안전 카운터

  void startMonitoring(String patientId) {
    if (_isMonitoring) return;

    _patientId = patientId;
    _isMonitoring = true;
    _lastStatus = null;
    _recentPositions.clear();
    _consecutiveOutsideCount = 0;
    _consecutiveInsideCount = 0;
    debugPrint("✅ [SafetyMonitor] 시스템 가동 시작: $patientId");

    // 1. 실시간 안심 구역 구독 (하위 컬렉션 감시)
    _zonesStream = FirebaseFirestore.instance
        .collection('users')
        .doc(patientId)
        .collection('safe_zones')
        .snapshots()
        .listen((snapshot) {
          _safeZones = snapshot.docs.map((doc) {
            final data = doc.data();
            return {
              'lat': (data['latitude'] as num).toDouble(),
              'lng': (data['longitude'] as num).toDouble(),
              'radius': (data['radius'] as num).toDouble(),
              'name': data['name'] ?? '알 수 없는 구역',
            };
          }).toList();
          debugPrint(
            "🔄 [SafetyMonitor] 감시 구역 동기화 완료: ${_safeZones.length}개 발견",
          );

          // ✅ [핵심 수정] 구역이 변경되면 즉시 현재 위치를 재검사합니다.
          // 새 구역이 시니어 위치와 멀리 떨어져있으면 바로 이탈이 감지되어야 합니다.
          _consecutiveOutsideCount = 0;
          _consecutiveInsideCount = 0;
          _lastStatus = null; // 상태 초기화 → 변경된 구역 기준으로 재판단
          _immediateZoneCheck();
        }, onError: (e) => debugPrint("❌ [SafetyMonitor] 구역 구독 에러: $e"));

    _startLocationStream();
  }

  void _startLocationStream() {
    // ✅ [수정] 더 민감한 위치 추적 설정
    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.best, // 최고 정확도
      distanceFilter: 5, // 5m 이동 시마다 갱신
    );

    _positionStream =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
          (Position position) {
            debugPrint(
              "📍 [SafetyMonitor] 위치 갱신: ${position.latitude}, ${position.longitude} (정확도: ${position.accuracy.toStringAsFixed(1)}m)",
            );
            _processPosition(position);
          },
          onError: (e) {
            debugPrint("❌ [SafetyMonitor] GPS 수신 오류: $e");
          },
        );

    // ✅ [수정] 5초마다 강제 위치 체크 (기존 30초 → 5초로 빠른 감지)
    Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!_isMonitoring) {
        timer.cancel();
        return;
      }
      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.best,
        );
        debugPrint(
          "⏰ [SafetyMonitor] 주기적 위치 체크: ${position.latitude}, ${position.longitude} (정확도: ${position.accuracy.toStringAsFixed(1)}m)",
        );
        _processPosition(position);
      } catch (e) {
        debugPrint("❌ [SafetyMonitor] 주기적 위치 체크 오류: $e");
      }
    });
  }

  // ✅ [신규] GPS Drift 필터링 후 지오펜스 체크
  void _processPosition(Position position) {
    // --- 필터 1: 정확도(accuracy) 기반 필터 ---
    // GPS accuracy가 너무 높으면(값이 클수록 부정확) 해당 데이터를 버림
    if (position.accuracy > _maxAcceptableAccuracy) {
      debugPrint(
        "🚫 [DriftFilter] 정확도 부족 (${position.accuracy.toStringAsFixed(1)}m > ${_maxAcceptableAccuracy}m) → 데이터 무시",
      );
      return;
    }

    // --- 필터 2: 최근 좌표 버퍼에 추가 ---
    _recentPositions.add(position);
    if (_recentPositions.length > _maxRecentPositions) {
      _recentPositions.removeAt(0);
    }

    // --- 필터 3: 표준편차(Standard Deviation) 기반 Drift 감지 ---
    if (_recentPositions.length >= 3) {
      final double stdDev = _calculatePositionStdDev();
      if (stdDev > _driftStdDevThreshold) {
        debugPrint(
          "🚫 [DriftFilter] 좌표 표준편차 과다 (${stdDev.toStringAsFixed(1)}m > ${_driftStdDevThreshold}m) → GPS 튀는 중, 판단 보류",
        );
        return;
      }
    }

    // 필터를 모두 통과한 신뢰할 수 있는 좌표로 지오펜스 체크
    _checkMultiGeofence(position);
  }

  // ✅ [신규] 최근 좌표들의 위치 표준편차 계산 (미터 단위)
  double _calculatePositionStdDev() {
    if (_recentPositions.length < 2) return 0.0;

    // 평균 좌표 계산
    double meanLat = 0, meanLng = 0;
    for (var pos in _recentPositions) {
      meanLat += pos.latitude;
      meanLng += pos.longitude;
    }
    meanLat /= _recentPositions.length;
    meanLng /= _recentPositions.length;

    // 각 좌표와 평균 간 거리(m)의 분산 계산
    double sumSquaredDistances = 0;
    for (var pos in _recentPositions) {
      final double dist = Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        meanLat,
        meanLng,
      );
      sumSquaredDistances += dist * dist;
    }

    return sqrt(sumSquaredDistances / _recentPositions.length);
  }

  void _checkMultiGeofence(Position currentPos) async {
    // 안심 구역이 설정되지 않은 경우, 비상 상황으로 간주하지 않고 보호자 설정을 기다림
    if (_safeZones.isEmpty) {
      debugPrint("⚠️ [SafetyMonitor] 설정된 안심 구역이 없어 감시를 대기합니다.");
      return;
    }

    bool isInsideAnyZone = false;
    String? detectedZone;

    for (var zone in _safeZones) {
      double distance = Geolocator.distanceBetween(
        currentPos.latitude,
        currentPos.longitude,
        zone['lat'],
        zone['lng'],
      );

      // ✅ [수정] 반경에 정확도 마진(accuracy)을 더해서 오차 보정
      // 예: 반경 30m + GPS 정확도 8m = 실제 판단 기준 38m
      final double effectiveRadius = zone['radius'] + currentPos.accuracy;

      debugPrint(
        "📍 [지오펜스 체크] 구역: ${zone['name']}, 거리: ${distance.toStringAsFixed(1)}m, "
        "반경: ${zone['radius']}m (+정확도 마진: ${effectiveRadius.toStringAsFixed(1)}m)",
      );

      if (distance <= effectiveRadius) {
        isInsideAnyZone = true;
        detectedZone = zone['name'];
        break;
      }
    }

    if (isInsideAnyZone) {
      _consecutiveOutsideCount = 0;
      _consecutiveInsideCount++;
      debugPrint(
        "🟢 [상태: 안전] 현재 '$detectedZone' 구역 내에 있음. (연속 안전: $_consecutiveInsideCount회)",
      );

      // 연속 2회 이상 안전 확인 시 상태를 safe로 변경
      if (_consecutiveInsideCount >= 2) {
        _updateStatus('safe', null);
      }
    } else {
      _consecutiveInsideCount = 0;
      _consecutiveOutsideCount++;
      debugPrint(
        "⚠️ [이탈 감지] 모든 안심 구역 밖 (연속 $_consecutiveOutsideCount/$_requiredConsecutiveOutside회)",
      );

      // ✅ [핵심] 연속 N회 이상 이탈 확인 시에만 비상으로 판단 (False Alarm 방지)
      if (_consecutiveOutsideCount >= _requiredConsecutiveOutside) {
        debugPrint(
          "🚨 [상태: 비상] 연속 ${_requiredConsecutiveOutside}회 이탈 확인 → 비상 알림 발송!",
        );
        _updateStatus('emergency', '안심 구역을 벗어났습니다. 위치 확인이 필요합니다.');
      }
    }
  }

  Future<void> _updateStatus(String status, String? message) async {
    if (_patientId == null || _lastStatus == status) return;

    try {
      // ✅ 명확한 상태 변화가 있을 때만 Firestore에 기록 (서버 알림 트리거용)
      await FirebaseFirestore.instance.collection('users').doc(_patientId).set({
        'status': status,
        'alertMessage': message ?? '',
        'lastStatusUpdate': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      _lastStatus = status;
      debugPrint("📡 [서버 전송] DB 상태 업데이트 완료: $status");
    } catch (e) {
      debugPrint("❌ [서버 전송] DB 업데이트 실패: $e");
    }
  }

  // ✅ [신규] 구역 변경 시 즉시 위치 재검사
  // 보호자가 새 구역을 설정하면 바로 시니어 위치를 확인하여 이탈 여부를 판단합니다.
  Future<void> _immediateZoneCheck() async {
    if (_safeZones.isEmpty) {
      debugPrint("⚠️ [즉시검사] 설정된 안심 구역이 없어 검사 생략");
      return;
    }

    try {
      final Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
      );
      debugPrint(
        "🔍 [즉시검사] 구역 변경 → 현재 위치 즉시 체크: "
        "${position.latitude}, ${position.longitude} (정확도: ${position.accuracy.toStringAsFixed(1)}m)",
      );

      // 정확도 필터는 유지 (GPS가 완전히 불안정하면 잘못된 판단 방지)
      if (position.accuracy > _maxAcceptableAccuracy) {
        debugPrint("🚫 [즉시검사] 정확도 부족 → 일반 모니터링에 위임");
        return;
      }

      // --- 모든 구역과의 거리를 계산하여 즉시 판단 ---
      bool isInsideAnyZone = false;
      double minDistanceOutside = double.infinity; // 가장 가까운 구역 경계까지의 거리

      for (var zone in _safeZones) {
        double distance = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          zone['lat'],
          zone['lng'],
        );
        final double effectiveRadius = zone['radius'] + position.accuracy;

        if (distance <= effectiveRadius) {
          isInsideAnyZone = true;
          break;
        } else {
          // 구역 경계를 벗어난 거리 (음수면 안에 있음)
          final double outsideDistance = distance - effectiveRadius;
          if (outsideDistance < minDistanceOutside) {
            minDistanceOutside = outsideDistance;
          }
        }
      }

      if (isInsideAnyZone) {
        debugPrint("🟢 [즉시검사] 시니어가 안심 구역 내에 있음 → safe");
        _consecutiveInsideCount = 2;
        _updateStatus('safe', null);
      } else {
        // ✅ [수정] 구역 밖이면 즉시 비상 알림 발송 (기존: 연속 체크 대기 → 수정: 바로 알림)
        // 보호자가 새 구역을 설정했고 시니어가 그 구역 밖에 있으면 즉시 알림
        debugPrint(
          "🚨 [즉시검사] 구역 경계에서 ${minDistanceOutside.toStringAsFixed(0)}m 떨어짐 → 즉시 비상 알림!",
        );
        _consecutiveOutsideCount = _requiredConsecutiveOutside;
        _updateStatus('emergency', '안심 구역을 벗어났습니다. 위치 확인이 필요합니다.');
      }
    } catch (e) {
      debugPrint("❌ [즉시검사] 현재 위치 가져오기 실패: $e");
    }
  }

  void stopMonitoring() {
    _positionStream?.cancel();
    _zonesStream?.cancel();
    _isMonitoring = false;
    _recentPositions.clear();
    _consecutiveOutsideCount = 0;
    _consecutiveInsideCount = 0;
    debugPrint("🛑 [SafetyMonitor] 시스템 종료");
  }
}
