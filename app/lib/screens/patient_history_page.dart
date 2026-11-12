import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:geolocator/geolocator.dart'; // ✅ 현재 위치용
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../theme_state.dart'; // ✅ [추가] 다크모드 지원

/// 위치 데이터 포인트 (필터링 및 분석용)
class LocationPoint {
  final double latitude;
  final double longitude;
  final double accuracy;
  final double speed;
  final DateTime timestamp;

  LocationPoint({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.speed,
    required this.timestamp,
  });

  NLatLng toNLatLng() => NLatLng(latitude, longitude);
}

/// 장소 (머문 곳) 정보
class StopPoint {
  final double latitude;
  final double longitude;
  final DateTime arrivalTime;
  final DateTime departureTime;
  final Duration duration;
  final StopType type;

  StopPoint({
    required this.latitude,
    required this.longitude,
    required this.arrivalTime,
    required this.departureTime,
    required this.duration,
    required this.type,
  });

  NLatLng toNLatLng() => NLatLng(latitude, longitude);
}

enum StopType { departure, arrival, stay }

/// ═══════════════════════════════════════════════════════════════════════════
/// 병합된 장소 정보 (같은 장소에 여러 번 방문한 경우 하나로 통합)
/// ═══════════════════════════════════════════════════════════════════════════
class MergedStop {
  final double latitude;
  final double longitude;
  final List<VisitRecord> visits; // 방문 기록 리스트
  final bool isStartPoint; // 출발지인지 여부
  final bool isEndPoint; // 도착지인지 여부
  final int visitOrder; // 첫 방문 순서 (경로 표시용)

  MergedStop({
    required this.latitude,
    required this.longitude,
    required this.visits,
    required this.isStartPoint,
    required this.isEndPoint,
    required this.visitOrder,
  });

  NLatLng toNLatLng() => NLatLng(latitude, longitude);

  // 총 머무른 시간 계산
  Duration get totalDuration =>
      visits.fold(Duration.zero, (sum, v) => sum + v.duration);
}

/// 개별 방문 기록
class VisitRecord {
  final DateTime arrivalTime;
  final DateTime departureTime;
  final Duration duration;

  VisitRecord({
    required this.arrivalTime,
    required this.departureTime,
    required this.duration,
  });
}

class PatientHistoryPage extends StatefulWidget {
  const PatientHistoryPage({super.key});

  @override
  State<PatientHistoryPage> createState() => _PatientHistoryPageState();
}

class _PatientHistoryPageState extends State<PatientHistoryPage> {
  NaverMapController? _mapController;
  List<Reference> _logFiles = [];
  bool _isLoading = true;
  String? _patientId;
  NLatLng? _currentLocation; // ✅ 현재 위치 저장

  // 선택된 날짜 표시용 변수
  String? _selectedDateDisplay;
  int? _selectedIndex;

  // ✅ [추가] 실시간 스트림 관련 변수
  StreamSubscription<DocumentSnapshot>? _realtimeSubscription;
  List<LocationPoint> _realtimePoints = []; // 실시간 누적 데이터
  bool _isRealtimeMode = false; // 실시간 모드 여부
  DateTime? _lastRealtimeUpdate; // 마지막 업데이트 시간

  // ═══════════════════════════════════════════════════════════════════════════
  // 필터링 임계값 상수 (민감도 조절 - 이동 기록이 더 잘 남도록 완화)
  // ═══════════════════════════════════════════════════════════════════════════
  static const double _maxAccuracy = 100.0; // 정확도 100m 초과 데이터 제외 (50→100 완화)
  static const double _minSpeedThreshold = 1.0; // 1.0 m/s 미만은 정지 상태 (유지)
  static const double _stayRadiusMeters = 50.0; // 50m 이내는 같은 장소 (30→50 완화)
  static const int _minStayDurationMinutes = 1; // 최소 1분 이상 머물러야 "머물음" (3→1 완화)

  @override
  void initState() {
    super.initState();
    _patientId = FirebaseAuth.instance.currentUser?.uid;
    _getCurrentLocation(); // ✅ 현재 위치 가져오기
    initializeDateFormatting('ko_KR', null).then((_) {
      _fetchLogFiles();
    });
  }

  @override
  void dispose() {
    _realtimeSubscription?.cancel(); // ✅ 실시간 스트림 해제
    super.dispose();
  }

  // ✅ [추가] 실시간 위치 스트림 시작 (오늘 날짜 데이터)
  void _startRealtimeStream() {
    if (_patientId == null) return;

    _realtimeSubscription?.cancel();
    _realtimePoints.clear();
    _lastRealtimeUpdate = null;

    // ✅ 먼저 UI 상태 업데이트
    setState(() {
      _isRealtimeMode = true;
      _selectedDateDisplay = "오늘 (실시간)";
      _selectedIndex = -1; // 특수 인덱스로 실시간 모드 표시
    });

    // ✅ 1단계: 오늘 날짜의 Storage 데이터 먼저 로드
    _loadTodayStorageData().then((_) {
      // ✅ 2단계: Storage 로드 후 Firestore 실시간 위치 구독 시작
      _realtimeSubscription = FirebaseFirestore.instance
          .collection('users')
          .doc(_patientId)
          .snapshots()
          .listen((snapshot) {
            if (!snapshot.exists || !mounted) return;

            final data = snapshot.data();
            if (data == null) return;

            // 현재 위치 데이터 추출
            final double? lat = data['currentLat']?.toDouble();
            final double? lng = data['currentLng']?.toDouble();
            final dynamic lastUpdatedRaw = data['lastUpdated'];

            if (lat == null || lng == null) return;

            // lastUpdated 파싱 (다양한 형식 지원)
            DateTime timestamp;
            if (lastUpdatedRaw is Timestamp) {
              timestamp = lastUpdatedRaw.toDate();
            } else if (lastUpdatedRaw is String) {
              timestamp = DateTime.tryParse(lastUpdatedRaw) ?? DateTime.now();
            } else {
              timestamp = DateTime.now();
            }

            // ✅ 오늘 데이터만 처리 (어제 데이터는 무시)
            final now = DateTime.now();
            if (timestamp.year != now.year ||
                timestamp.month != now.month ||
                timestamp.day != now.day) {
              return;
            }

            // ✅ 중복 방지: 같은 시간의 데이터면 스킵 (10초 내)
            if (_lastRealtimeUpdate != null &&
                timestamp.difference(_lastRealtimeUpdate!).inSeconds.abs() <
                    10) {
              return;
            }

            // ✅ 이미 있는 포인트와 중복 확인
            bool isDuplicate = _realtimePoints.any(
              (p) =>
                  (p.timestamp.difference(timestamp).inSeconds.abs() < 10) &&
                  (_calculateDistance(p.latitude, p.longitude, lat, lng) < 10),
            );
            if (isDuplicate) return;

            _lastRealtimeUpdate = timestamp;

            // 새 위치 포인트 추가
            final newPoint = LocationPoint(
              latitude: lat,
              longitude: lng,
              accuracy: 0.0, // 실시간 데이터는 정확도 0으로 처리 (필터링 통과)
              speed: 0.0,
              timestamp: timestamp,
            );

            setState(() {
              _realtimePoints.add(newPoint);
              // 시간순 정렬
              _realtimePoints.sort(
                (a, b) => a.timestamp.compareTo(b.timestamp),
              );
            });

            // 지도 업데이트
            _processAndDrawRealtimeData();
          });
    });
  }

  // ✅ [추가] 오늘 날짜의 Storage 데이터 로드
  Future<void> _loadTodayStorageData() async {
    if (_patientId == null) return;

    try {
      final String today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final String storagePath =
          "Users/$_patientId/source/locations/$today.json";

      final ref = FirebaseStorage.instance.ref(storagePath);
      final dataBytes = await ref.getData(10485760);

      if (dataBytes != null) {
        String jsonString = utf8.decode(dataBytes);
        List<dynamic> jsonList = jsonDecode(jsonString);
        List<LocationPoint> storagePoints = _parseLocationData(jsonList);

        // ✅ 오늘 데이터만 필터링
        final now = DateTime.now();
        storagePoints = storagePoints
            .where(
              (p) =>
                  p.timestamp.year == now.year &&
                  p.timestamp.month == now.month &&
                  p.timestamp.day == now.day,
            )
            .toList();

        if (mounted && storagePoints.isNotEmpty) {
          setState(() {
            // Storage 데이터를 실시간 데이터 앞에 추가 (시간순 정렬)
            _realtimePoints = [...storagePoints, ..._realtimePoints];
            // 중복 제거 (같은 시간대 데이터)
            _realtimePoints = _removeDuplicatePoints(_realtimePoints);
          });
          debugPrint("📂 오늘 Storage 데이터 ${storagePoints.length}개 로드 완료");
          _processAndDrawRealtimeData();
        }
      }
    } catch (e) {
      debugPrint("📂 오늘 Storage 데이터 로드 실패 (아직 업로드되지 않음): $e");
      // ✅ Storage 데이터가 없어도 오류가 아님 - 실시간 데이터만 표시됨
    }
  }

  // ✅ [추가] 중복 포인트 제거
  List<LocationPoint> _removeDuplicatePoints(List<LocationPoint> points) {
    if (points.isEmpty) return points;
    points.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    List<LocationPoint> unique = [points.first];
    for (int i = 1; i < points.length; i++) {
      if (points[i].timestamp.difference(unique.last.timestamp).inSeconds > 5) {
        unique.add(points[i]);
      }
    }
    return unique;
  }

  // ✅ [추가] 실시간 데이터 처리 및 지도 그리기
  Future<void> _processAndDrawRealtimeData() async {
    if (_mapController == null || !mounted) return;

    // ✅ 데이터가 없으면 현재 위치만 표시
    if (_realtimePoints.isEmpty) {
      if (_currentLocation != null) {
        _mapController!.clearOverlays();
        final marker = NMarker(
          id: 'current_location',
          position: _currentLocation!,
          caption: NOverlayCaption(
            text: '📍 현재 위치',
            color: Colors.blue,
            haloColor: Colors.white,
            textSize: 14,
          ),
          iconTintColor: Colors.blue,
        );
        _mapController!.addOverlay(marker);
        await _mapController!.updateCamera(
          NCameraUpdate.scrollAndZoomTo(target: _currentLocation!, zoom: 15),
        );
      }
      return;
    }

    // 정확도 필터링
    List<LocationPoint> accuratePoints = _filterByAccuracy(_realtimePoints);
    if (accuratePoints.isEmpty) accuratePoints = _realtimePoints;

    // ✅ 데이터가 1개만 있으면 해당 위치만 표시
    if (accuratePoints.length == 1) {
      _mapController!.clearOverlays();
      final point = accuratePoints.first;
      final marker = NMarker(
        id: 'single_point',
        position: point.toNLatLng(),
        caption: NOverlayCaption(
          text: '📍 ${DateFormat("HH:mm").format(point.timestamp)}',
          color: Colors.purple,
          haloColor: Colors.white,
          textSize: 14,
        ),
        iconTintColor: Colors.purple,
      );
      _mapController!.addOverlay(marker);
      await _mapController!.updateCamera(
        NCameraUpdate.scrollAndZoomTo(target: point.toNLatLng(), zoom: 15),
      );
      return;
    }

    // 정지 상태 병합
    List<LocationPoint> mergedPoints = _mergeStationaryPoints(accuratePoints);

    // 장소 감지
    List<StopPoint> stops = _detectStops(mergedPoints);

    // ✅ 장소가 없으면 원본 포인트로 간단히 표시
    if (stops.isEmpty) {
      await _drawSimplePath(accuratePoints);
      return;
    }

    // 같은 장소 병합
    List<MergedStop> mergedStops = _mergeNearbyStops(stops);

    // 지도에 그리기
    await _drawMergedStopsOnMap(
      mergedStops,
      _realtimePoints.length,
      accuratePoints.length,
    );
  }

  // ✅ [신규] 간단한 경로 표시 (장소 감지 없이 포인트만 표시)
  Future<void> _drawSimplePath(List<LocationPoint> points) async {
    if (_mapController == null || points.isEmpty || !mounted) return;

    _mapController!.clearOverlays();

    List<NLatLng> pathCoords = points.map((p) => p.toNLatLng()).toList();

    // 경로 선 그리기
    if (pathCoords.length >= 2) {
      final pathOverlay = NPathOverlay(
        id: 'simple_path',
        coords: pathCoords,
        color: const Color(0xFF2196F3),
        width: 4,
        outlineColor: Colors.white,
        outlineWidth: 1,
      );
      _mapController!.addOverlay(pathOverlay);
    }

    // 시작점 마커
    final startMarker = NMarker(
      id: 'start_point',
      position: pathCoords.first,
      caption: NOverlayCaption(
        text: '🚶 시작 ${DateFormat("HH:mm").format(points.first.timestamp)}',
        color: Colors.blue,
        haloColor: Colors.white,
        textSize: 12,
      ),
      iconTintColor: Colors.blue,
    );
    _mapController!.addOverlay(startMarker);

    // 끝점 마커
    final endMarker = NMarker(
      id: 'end_point',
      position: pathCoords.last,
      caption: NOverlayCaption(
        text: '🏁 현재 ${DateFormat("HH:mm").format(points.last.timestamp)}',
        color: Colors.red,
        haloColor: Colors.white,
        textSize: 12,
      ),
      iconTintColor: Colors.red,
    );
    _mapController!.addOverlay(endMarker);

    // 카메라 이동
    final bounds = NLatLngBounds.from(pathCoords);
    await _mapController!.updateCamera(
      NCameraUpdate.fitBounds(bounds, padding: const EdgeInsets.all(80)),
    );
  }

  // ✅ [추가] 실시간 모드 중지
  void _stopRealtimeStream() {
    _realtimeSubscription?.cancel();
    _realtimeSubscription = null;
    _lastRealtimeUpdate = null;

    // ✅ UI 상태 업데이트
    if (mounted) {
      setState(() {
        _isRealtimeMode = false;
        _realtimePoints.clear();
      });
    } else {
      _isRealtimeMode = false;
      _realtimePoints.clear();
    }
  }

  // ✅ 현재 위치 가져오기
  Future<void> _getCurrentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (mounted) {
        setState(() {
          _currentLocation = NLatLng(position.latitude, position.longitude);
        });
      }
    } catch (e) {
      debugPrint("현재 위치 가져오기 실패: $e");
    }
  }

  // ✅ 현재 위치로 카메라 이동
  Future<void> _moveToCurrentLocation() async {
    if (_mapController == null) return;

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      final currentLatLng = NLatLng(position.latitude, position.longitude);

      await _mapController!.updateCamera(
        NCameraUpdate.scrollAndZoomTo(target: currentLatLng, zoom: 15),
      );

      if (mounted) {
        setState(() => _currentLocation = currentLatLng);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("현재 위치를 가져올 수 없습니다.")));
      }
    }
  }

  // 📂 파일 목록 가져오기
  Future<void> _fetchLogFiles() async {
    if (_patientId == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      final String targetPath = "Users/$_patientId/source/locations";
      final listResult = await FirebaseStorage.instance
          .ref()
          .child(targetPath)
          .listAll();

      setState(() {
        _logFiles = listResult.items;
        _logFiles.sort((a, b) => b.name.compareTo(a.name));
        _isLoading = false;
      });
    } catch (e) {
      debugPrint("파일 목록 로드 실패: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 🧹 2차 개선: 정확도 + 속도 기반 필터링 & 장소 감지 알고리즘
  // ═══════════════════════════════════════════════════════════════════════════

  /// 두 좌표 간 거리 계산 (Haversine 공식, 미터 단위)
  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double earthRadius = 6371000;
    final double dLat = _toRadians(lat2 - lat1);
    final double dLon = _toRadians(lon2 - lon1);
    final double a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(lat1)) *
            cos(_toRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  double _toRadians(double degrees) => degrees * pi / 180;

  /// JSON 데이터를 LocationPoint 리스트로 파싱
  List<LocationPoint> _parseLocationData(List<dynamic> jsonList) {
    List<LocationPoint> points = [];
    debugPrint("📊 [파싱 시작] 총 ${jsonList.length}개 데이터");

    for (var log in jsonList) {
      try {
        // ✅ 실제 저장된 키 이름: lat, lng (latitude/longitude 둘 다 지원)
        double? lat =
            (log['lat'] as num?)?.toDouble() ??
            (log['latitude'] as num?)?.toDouble();
        double? lng =
            (log['lng'] as num?)?.toDouble() ??
            (log['longitude'] as num?)?.toDouble();
        // ✅ accuracy가 없으면 0.0으로 (필터링 통과)
        double accuracy = (log['accuracy'] as num?)?.toDouble() ?? 0.0;
        double speed = (log['speed'] as num?)?.toDouble() ?? 0.0;

        // timestamp 파싱 (다양한 형식 지원)
        DateTime? timestamp;
        if (log['timestamp'] != null) {
          if (log['timestamp'] is String) {
            timestamp = DateTime.tryParse(log['timestamp']);
          } else if (log['timestamp'] is int) {
            timestamp = DateTime.fromMillisecondsSinceEpoch(log['timestamp']);
          }
        }

        // 필수 데이터가 없으면 스킵
        if (lat == null || lng == null || timestamp == null) {
          debugPrint("⚠️ [스킵] lat=$lat, lng=$lng, timestamp=$timestamp");
          continue;
        }

        points.add(
          LocationPoint(
            latitude: lat,
            longitude: lng,
            accuracy: accuracy,
            speed: speed < 0 ? 0 : speed, // 음수 속도 보정
            timestamp: timestamp,
          ),
        );
      } catch (e) {
        debugPrint("❌ [파싱 에러] $e");
        continue;
      }
    }

    debugPrint("✅ [파싱 완료] ${points.length}개 포인트 생성");
    // 시간순 정렬
    points.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return points;
  }

  /// 1단계: 정확도 필터링 - 부정확한 GPS 데이터 제거
  List<LocationPoint> _filterByAccuracy(List<LocationPoint> points) {
    return points.where((p) => p.accuracy <= _maxAccuracy).toList();
  }

  /// 2단계: 정지 상태 병합 - 속도가 낮으면 이전 위치 유지
  List<LocationPoint> _mergeStationaryPoints(List<LocationPoint> points) {
    if (points.isEmpty) return points;

    List<LocationPoint> merged = [points.first];

    for (int i = 1; i < points.length; i++) {
      LocationPoint current = points[i];
      LocationPoint lastMerged = merged.last;

      // 속도가 임계값 미만이면 정지 상태로 판단
      if (current.speed < _minSpeedThreshold) {
        // 이전 위치와의 거리 확인
        double dist = _calculateDistance(
          lastMerged.latitude,
          lastMerged.longitude,
          current.latitude,
          current.longitude,
        );

        // 거리도 가까우면 (30m 이내) 같은 위치로 간주하고 스킵
        if (dist < _stayRadiusMeters) {
          continue;
        }
      }

      merged.add(current);
    }

    return merged;
  }

  /// 3단계: 장소(Stop) 감지 - 출발, 도착, 머물음 포인트 추출
  List<StopPoint> _detectStops(List<LocationPoint> points) {
    if (points.isEmpty) return [];

    List<StopPoint> stops = [];
    List<LocationPoint> currentCluster = [points.first];
    DateTime clusterStartTime = points.first.timestamp;

    for (int i = 1; i < points.length; i++) {
      LocationPoint current = points[i];

      // 클러스터 중심 계산
      double centerLat =
          currentCluster.map((p) => p.latitude).reduce((a, b) => a + b) /
          currentCluster.length;
      double centerLng =
          currentCluster.map((p) => p.longitude).reduce((a, b) => a + b) /
          currentCluster.length;

      double distFromCenter = _calculateDistance(
        current.latitude,
        current.longitude,
        centerLat,
        centerLng,
      );

      if (distFromCenter <= _stayRadiusMeters) {
        // 같은 장소에 계속 머무름
        currentCluster.add(current);
      } else {
        // 새로운 장소로 이동 - 이전 클러스터를 장소로 저장
        DateTime clusterEndTime = currentCluster.last.timestamp;
        Duration stayDuration = clusterEndTime.difference(clusterStartTime);

        // 중심점 재계산
        centerLat =
            currentCluster.map((p) => p.latitude).reduce((a, b) => a + b) /
            currentCluster.length;
        centerLng =
            currentCluster.map((p) => p.longitude).reduce((a, b) => a + b) /
            currentCluster.length;

        // 최소 체류 시간 이상이면 장소로 등록
        if (stayDuration.inMinutes >= _minStayDurationMinutes ||
            stops.isEmpty) {
          stops.add(
            StopPoint(
              latitude: centerLat,
              longitude: centerLng,
              arrivalTime: clusterStartTime,
              departureTime: clusterEndTime,
              duration: stayDuration,
              type: stops.isEmpty ? StopType.departure : StopType.stay,
            ),
          );
        }

        // 새 클러스터 시작
        currentCluster = [current];
        clusterStartTime = current.timestamp;
      }
    }

    // 마지막 클러스터 처리 (도착점)
    if (currentCluster.isNotEmpty) {
      double centerLat =
          currentCluster.map((p) => p.latitude).reduce((a, b) => a + b) /
          currentCluster.length;
      double centerLng =
          currentCluster.map((p) => p.longitude).reduce((a, b) => a + b) /
          currentCluster.length;
      DateTime clusterEndTime = currentCluster.last.timestamp;
      Duration stayDuration = clusterEndTime.difference(clusterStartTime);

      stops.add(
        StopPoint(
          latitude: centerLat,
          longitude: centerLng,
          arrivalTime: clusterStartTime,
          departureTime: clusterEndTime,
          duration: stayDuration,
          type: StopType.arrival,
        ),
      );
    }

    // 첫 번째를 출발, 마지막을 도착으로 설정
    if (stops.isNotEmpty) {
      stops[0] = StopPoint(
        latitude: stops[0].latitude,
        longitude: stops[0].longitude,
        arrivalTime: stops[0].arrivalTime,
        departureTime: stops[0].departureTime,
        duration: stops[0].duration,
        type: StopType.departure,
      );
    }
    if (stops.length > 1) {
      int lastIdx = stops.length - 1;
      stops[lastIdx] = StopPoint(
        latitude: stops[lastIdx].latitude,
        longitude: stops[lastIdx].longitude,
        arrivalTime: stops[lastIdx].arrivalTime,
        departureTime: stops[lastIdx].departureTime,
        duration: stops[lastIdx].duration,
        type: StopType.arrival,
      );
    }

    return stops;
  }

  /// ═══════════════════════════════════════════════════════════════════════════
  /// 4단계: 같은 장소 병합 - 근처 장소들을 하나로 통합
  /// ═══════════════════════════════════════════════════════════════════════════
  List<MergedStop> _mergeNearbyStops(List<StopPoint> stops) {
    if (stops.isEmpty) return [];

    // 같은 장소 병합을 위한 임계값 (100m 이내면 같은 장소로 판단)
    const double mergeRadiusMeters = 100.0;

    List<MergedStop> mergedStops = [];
    List<bool> processed = List.filled(stops.length, false);

    for (int i = 0; i < stops.length; i++) {
      if (processed[i]) continue;

      StopPoint baseStop = stops[i];
      List<int> sameLocationIndices = [i];

      // 같은 장소 찾기
      for (int j = i + 1; j < stops.length; j++) {
        if (processed[j]) continue;

        double distance = _calculateDistance(
          baseStop.latitude,
          baseStop.longitude,
          stops[j].latitude,
          stops[j].longitude,
        );

        if (distance <= mergeRadiusMeters) {
          sameLocationIndices.add(j);
        }
      }

      // 같은 장소의 모든 방문을 병합
      List<VisitRecord> visits = [];
      double avgLat = 0;
      double avgLng = 0;

      for (int idx in sameLocationIndices) {
        processed[idx] = true;
        StopPoint stop = stops[idx];

        avgLat += stop.latitude;
        avgLng += stop.longitude;

        visits.add(
          VisitRecord(
            arrivalTime: stop.arrivalTime,
            departureTime: stop.departureTime,
            duration: stop.duration,
          ),
        );
      }

      avgLat /= sameLocationIndices.length;
      avgLng /= sameLocationIndices.length;

      // 방문 시간순 정렬
      visits.sort((a, b) => a.arrivalTime.compareTo(b.arrivalTime));

      // 출발지/도착지 판단
      bool isStart = sameLocationIndices.contains(0);
      bool isEnd = sameLocationIndices.contains(stops.length - 1);

      mergedStops.add(
        MergedStop(
          latitude: avgLat,
          longitude: avgLng,
          visits: visits,
          isStartPoint: isStart,
          isEndPoint: isEnd,
          visitOrder: sameLocationIndices.first,
        ),
      );
    }

    // 첫 방문 순서대로 정렬
    mergedStops.sort((a, b) => a.visitOrder.compareTo(b.visitOrder));

    return mergedStops;
  }

  /// 시간 포맷팅 헬퍼
  String _formatTime(DateTime time) {
    return DateFormat('HH:mm', 'ko_KR').format(time);
  }

  String _formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      return "${duration.inHours}시간 ${duration.inMinutes % 60}분";
    } else if (duration.inMinutes > 0) {
      return "${duration.inMinutes}분";
    } else {
      return "${duration.inSeconds}초";
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════

  // 🗺️ 파일 내용 읽어서 지도에 그리기
  Future<void> _loadAndDrawPath(Reference ref, int index) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final dataBytes = await ref.getData(10485760);
      if (dataBytes == null) throw Exception("데이터 없음");

      String jsonString = utf8.decode(dataBytes);
      List<dynamic> jsonList = jsonDecode(jsonString);

      // 1. JSON → LocationPoint 파싱
      List<LocationPoint> rawPoints = _parseLocationData(jsonList);

      if (!mounted) return;
      Navigator.pop(context);

      if (rawPoints.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("이동 기록 좌표가 없습니다.")));
        return;
      }

      // 선택된 날짜 업데이트
      setState(() {
        _selectedDateDisplay = _getSimpleDateFromFileName(ref.name);
        _selectedIndex = index;
      });

      // 2. 정확도 필터링
      List<LocationPoint> accuratePoints = _filterByAccuracy(rawPoints);

      // 3. 정지 상태 병합
      List<LocationPoint> mergedPoints = _mergeStationaryPoints(accuratePoints);

      // 4. 장소(Stop) 감지
      List<StopPoint> stops = _detectStops(mergedPoints);

      if (stops.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("분석 가능한 이동 데이터가 없습니다.")));
        return;
      }

      // 5. 같은 장소 병합 (100m 이내는 같은 장소로 판단)
      List<MergedStop> mergedStops = _mergeNearbyStops(stops);

      // 6. 지도에 그리기
      await _drawMergedStopsOnMap(
        mergedStops,
        rawPoints.length,
        accuratePoints.length,
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      debugPrint("파일 로드 에러: $e");
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("파일을 불러오는데 실패했습니다.")));
    }
  }

  /// ═══════════════════════════════════════════════════════════════════════════
  /// 지도에 병합된 장소 핑과 경로 그리기 (개선된 버전)
  /// ═══════════════════════════════════════════════════════════════════════════
  Future<void> _drawMergedStopsOnMap(
    List<MergedStop> mergedStops,
    int originalCount,
    int filteredCount,
  ) async {
    if (_mapController == null || mergedStops.isEmpty) return;

    _mapController!.clearOverlays();

    // 핑들의 좌표 리스트 (선 연결용)
    List<NLatLng> pathCoords = mergedStops.map((s) => s.toNLatLng()).toList();

    // 1. 핑과 핑을 잇는 직선 경로
    if (pathCoords.length >= 2) {
      final pathOverlay = NPathOverlay(
        id: 'route_path',
        coords: pathCoords,
        color: const Color(0xFF2E7D32),
        width: 6,
        outlineColor: Colors.white,
        outlineWidth: 2,
      );
      _mapController!.addOverlay(pathOverlay);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 이동 여부 판단: 장소가 1개뿐이고 출발지=도착지인 경우 "이동 없음"
    // ═══════════════════════════════════════════════════════════════════════
    bool isSingleStayLocation =
        mergedStops.length == 1 &&
        mergedStops.first.isStartPoint &&
        mergedStops.first.isEndPoint;

    // 2. 각 장소에 마커 추가 (병합된 정보 표시)
    for (int i = 0; i < mergedStops.length; i++) {
      final stop = mergedStops[i];
      String caption = _buildMergedCaption(
        stop,
        isSingleStayLocation: isSingleStayLocation,
      );
      Color markerColor = _getMergedMarkerColor(
        stop,
        isSingleStayLocation: isSingleStayLocation,
      );

      final marker = NMarker(
        id: 'merged_stop_$i',
        position: stop.toNLatLng(),
        caption: NOverlayCaption(
          text: caption,
          color: markerColor,
          haloColor: Colors.white,
          textSize: 12,
        ),
        iconTintColor: markerColor,
      );
      _mapController!.addOverlay(marker);
    }

    // 3. 카메라 이동
    if (pathCoords.isNotEmpty) {
      final bounds = NLatLngBounds.from(pathCoords);
      final cameraUpdate = NCameraUpdate.fitBounds(
        bounds,
        padding: const EdgeInsets.all(80),
      );
      await _mapController!.updateCamera(cameraUpdate);
    }
  }

  /// 병합된 장소의 캡션 생성 (이동 여부에 따라 다르게 표시)
  /// [isSingleStayLocation]: 전체 장소가 1개뿐이고 실제 이동 없이 머물기만 한 경우
  String _buildMergedCaption(
    MergedStop stop, {
    bool isSingleStayLocation = false,
  }) {
    List<String> lines = [];

    // ═══════════════════════════════════════════════════════════════════════
    // 케이스 1: 이동 없이 한 장소에만 머문 경우 (출발/도착 대신 머무름만 표시)
    // ═══════════════════════════════════════════════════════════════════════
    if (isSingleStayLocation) {
      VisitRecord firstVisit = stop.visits.first;
      VisitRecord lastVisit = stop.visits.last;

      // 첫 데이터 시작 ~ 마지막 데이터 끝까지의 총 체류 시간
      Duration totalStay = lastVisit.departureTime.difference(
        firstVisit.arrivalTime,
      );

      lines.add("📍 머무름");
      lines.add(
        "${_formatTime(firstVisit.arrivalTime)} ~ ${_formatTime(lastVisit.departureTime)}",
      );
      lines.add("(${_formatDuration(totalStay)})");
      return lines.join('\n');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 케이스 2: 실제 이동이 있는 경우 (출발/도착 정보 표시)
    // ═══════════════════════════════════════════════════════════════════════

    // 출발지이면서 도착지인 경우 (집에서 출발해서 다시 집으로 돌아온 경우)
    if (stop.isStartPoint && stop.isEndPoint && stop.visits.length >= 2) {
      // 첫 방문 = 출발, 마지막 방문 = 도착
      VisitRecord firstVisit = stop.visits.first;
      VisitRecord lastVisit = stop.visits.last;
      lines.add("🏠 출발 ${_formatTime(firstVisit.departureTime)}");
      lines.add("🏠 복귀 ${_formatTime(lastVisit.arrivalTime)}");
    }
    // 출발지만인 경우
    else if (stop.isStartPoint) {
      VisitRecord visit = stop.visits.first;
      lines.add("🚶 출발 ${_formatTime(visit.departureTime)}");
    }
    // 도착지만인 경우
    else if (stop.isEndPoint) {
      VisitRecord visit = stop.visits.last;
      lines.add("🏁 도착 ${_formatTime(visit.arrivalTime)}");
      if (visit.duration.inMinutes >= 1) {
        lines.add("머무름 ${_formatDuration(visit.duration)}");
      }
    }
    // 중간 경유지 (여러 번 방문 가능)
    else {
      for (int i = 0; i < stop.visits.length; i++) {
        VisitRecord visit = stop.visits[i];
        if (stop.visits.length > 1) {
          // 여러 번 방문한 경우
          lines.add("📍 ${i + 1}차 방문");
          lines.add(
            "${_formatTime(visit.arrivalTime)}~${_formatTime(visit.departureTime)}",
          );
          if (visit.duration.inMinutes >= 1) {
            lines.add("(${_formatDuration(visit.duration)})");
          }
          if (i < stop.visits.length - 1) {
            lines.add("---"); // 구분선
          }
        } else {
          // 한 번만 방문한 경우
          lines.add("📍 경유");
          lines.add(
            "${_formatTime(visit.arrivalTime)}~${_formatTime(visit.departureTime)}",
          );
          if (visit.duration.inMinutes >= 1) {
            lines.add("(${_formatDuration(visit.duration)})");
          }
        }
      }
    }

    return lines.join('\n');
  }

  /// 병합된 장소의 마커 색상 결정
  /// [isSingleStayLocation]: 한 장소에만 머문 경우 (이동 없음)
  Color _getMergedMarkerColor(
    MergedStop stop, {
    bool isSingleStayLocation = false,
  }) {
    // 이동 없이 한 장소에만 머문 경우 - 보라색
    if (isSingleStayLocation) {
      return Colors.purple;
    }
    if (stop.isStartPoint && stop.isEndPoint) {
      // 출발지이자 도착지 (집)
      return Colors.cyan;
    } else if (stop.isStartPoint) {
      return Colors.blue;
    } else if (stop.isEndPoint) {
      return Colors.red;
    } else {
      return Colors.orange;
    }
  }

  // 파일명에서 간단한 날짜 추출
  String _getSimpleDateFromFileName(String fileName) {
    try {
      final RegExp dateRegExp = RegExp(r'(\d{4}-\d{2}-\d{2})');
      final match = dateRegExp.firstMatch(fileName);
      if (match != null) {
        return match.group(0)!;
      }
    } catch (_) {}
    return fileName.replaceAll(".json", "");
  }

  // 파일 이름 변환
  String _formatFileName(String fileName) {
    try {
      String nameWithoutExt = fileName.replaceAll(".json", "");
      DateFormat inputFormat = DateFormat("yyyy-MM-dd_HH-mm");
      DateTime date = inputFormat.parse(nameWithoutExt);
      return DateFormat('yyyy년 M월 d일 (E) a h:mm', 'ko_KR').format(date);
    } catch (e) {
      try {
        final RegExp dateRegExp = RegExp(r'(\d{4}-\d{2}-\d{2})');
        final match = dateRegExp.firstMatch(fileName);
        if (match != null) {
          return match.group(0)!;
        }
      } catch (_) {}
      return fileName;
    }
  }

  @override
  Widget build(BuildContext context) {
    // ✅ [개선] 다크모드 지원
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? AppColors.darkBackground : Colors.white;
    final surfaceColor = isDark ? AppColors.darkSurface : Colors.white;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black87;
    final subTextColor = isDark ? AppColors.darkOnSurfaceVariant : Colors.grey;
    final listBgColor = isDark
        ? AppColors.darkBackground
        : const Color(0xFFF5F5F5);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Text("나의 이동 기록", style: TextStyle(color: textColor)),
        backgroundColor: backgroundColor,
        foregroundColor: textColor,
        elevation: 0,
      ),
      body: Column(
        children: [
          // 선택된 날짜 표시 영역
          if (_selectedDateDisplay != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF2E7D32).withOpacity(isDark ? 0.2 : 0.1),
                border: Border(
                  bottom: BorderSide(
                    color: const Color(0xFF2E7D32).withOpacity(0.3),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.calendar_today,
                    color: isDark
                        ? AppColors.successDark
                        : const Color(0xFF2E7D32),
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    "선택된 날짜: $_selectedDateDisplay",
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isDark
                          ? AppColors.successDark
                          : const Color(0xFF2E7D32),
                    ),
                  ),
                ],
              ),
            ),

          Expanded(
            flex: 6,
            child: Stack(
              children: [
                NaverMap(
                  options: NaverMapViewOptions(
                    mapType: NMapType.basic,
                    activeLayerGroups: [
                      NLayerGroup.building,
                      NLayerGroup.transit,
                    ],
                    initialCameraPosition: NCameraPosition(
                      target:
                          _currentLocation ?? const NLatLng(37.5665, 126.9780),
                      zoom: _currentLocation != null ? 15 : 10,
                    ),
                    locationButtonEnable: false, // ✅ 커스텀 버튼 사용
                  ),
                  onMapReady: (controller) {
                    _mapController = controller;
                    // ✅ 현재 위치로 카메라 이동
                    if (_currentLocation != null) {
                      controller.updateCamera(
                        NCameraUpdate.scrollAndZoomTo(
                          target: _currentLocation!,
                          zoom: 15,
                        ),
                      );
                    }
                  },
                ),
                // ✅ 현재 위치 버튼 (좌하단)
                Positioned(
                  left: 16,
                  bottom: 16,
                  child: FloatingActionButton.small(
                    heroTag: "patient_history_location_btn",
                    backgroundColor: surfaceColor,
                    onPressed: _moveToCurrentLocation,
                    child: Icon(
                      Icons.my_location,
                      color: isDark
                          ? AppColors.successDark
                          : const Color(0xFF2E7D32),
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            flex: 4,
            child: Container(
              color: listBgColor,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 15,
                    ),
                    color: surfaceColor,
                    width: double.infinity,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "📅 날짜별 기록",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            color: textColor,
                          ),
                        ),
                        // ✅ [추가] 실시간 버튼
                        TextButton.icon(
                          onPressed: () {
                            if (_isRealtimeMode) {
                              _stopRealtimeStream();
                              _mapController?.clearOverlays();
                              setState(() {
                                _selectedDateDisplay = null;
                                _selectedIndex = null;
                              });
                            } else {
                              _startRealtimeStream();
                            }
                          },
                          icon: Icon(
                            _isRealtimeMode ? Icons.stop : Icons.stream,
                            size: 18,
                            color: _isRealtimeMode
                                ? Colors.red
                                : (isDark
                                      ? AppColors.successDark
                                      : const Color(0xFF2E7D32)),
                          ),
                          label: Text(
                            _isRealtimeMode ? "중지" : "실시간",
                            style: TextStyle(
                              color: _isRealtimeMode
                                  ? Colors.red
                                  : (isDark
                                        ? AppColors.successDark
                                        : const Color(0xFF2E7D32)),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          style: TextButton.styleFrom(
                            backgroundColor: _isRealtimeMode
                                ? Colors.red.withOpacity(0.1)
                                : const Color(
                                    0xFF2E7D32,
                                  ).withOpacity(isDark ? 0.2 : 0.1),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: isDark ? AppColors.darkDivider : null,
                  ),
                  Expanded(
                    child: _isLoading
                        ? const Center(child: CircularProgressIndicator())
                        : _logFiles.isEmpty && !_isRealtimeMode
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.folder_off,
                                  size: 40,
                                  color: subTextColor,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  "저장된 기록이 없습니다.",
                                  style: TextStyle(color: subTextColor),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  "'실시간' 버튼을 눌러 오늘 이동을 확인하세요",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark
                                        ? AppColors.successDark
                                        : const Color(0xFF2E7D32),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount:
                                _logFiles.length +
                                1, // +1 for "오늘 (실시간)" option
                            itemBuilder: (context, index) {
                              // ✅ [추가] 첫 번째 항목은 "오늘 (실시간)"
                              if (index == 0) {
                                bool isSelected = _selectedIndex == -1;
                                return Container(
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? Colors.blue.withOpacity(
                                            isDark ? 0.25 : 0.15,
                                          )
                                        : surfaceColor,
                                    borderRadius: BorderRadius.circular(12),
                                    border: isSelected
                                        ? Border.all(
                                            color: Colors.blue,
                                            width: 2,
                                          )
                                        : Border.all(
                                            color: Colors.blue.withOpacity(0.3),
                                            width: 1,
                                          ),
                                    boxShadow: isDark
                                        ? []
                                        : [
                                            BoxShadow(
                                              color: Colors.grey.withOpacity(
                                                0.1,
                                              ),
                                              blurRadius: 5,
                                              offset: const Offset(0, 2),
                                            ),
                                          ],
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 8,
                                    ),
                                    leading: Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: Colors.blue.withOpacity(
                                          isDark ? 0.3 : 0.2,
                                        ),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        isSelected ? Icons.stream : Icons.today,
                                        color: Colors.blue,
                                        size: 20,
                                      ),
                                    ),
                                    title: Text(
                                      "📍 오늘 (실시간)",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                        color: Colors.blue,
                                      ),
                                    ),
                                    subtitle: Text(
                                      _isRealtimeMode
                                          ? "실시간 추적 중... (${_realtimePoints.length}개 포인트)"
                                          : "탭하여 실시간 위치 추적 시작",
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: _isRealtimeMode
                                            ? Colors.blue
                                            : subTextColor,
                                      ),
                                    ),
                                    trailing: _isRealtimeMode
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                    Colors.blue,
                                                  ),
                                            ),
                                          )
                                        : Icon(
                                            Icons.arrow_forward_ios,
                                            size: 14,
                                            color: Colors.blue,
                                          ),
                                    onTap: () {
                                      if (!_isRealtimeMode) {
                                        _startRealtimeStream();
                                      }
                                    },
                                  ),
                                );
                              }

                              // 기존 파일 목록 (인덱스 -1 보정)
                              final fileIndex = index - 1;
                              final file = _logFiles[fileIndex];
                              String displayName = _formatFileName(file.name);
                              bool isSelected = _selectedIndex == fileIndex;

                              return Container(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(
                                          0xFF2E7D32,
                                        ).withOpacity(isDark ? 0.3 : 0.1)
                                      : surfaceColor,
                                  borderRadius: BorderRadius.circular(12),
                                  border: isSelected
                                      ? Border.all(
                                          color: isDark
                                              ? AppColors.successDark
                                              : const Color(0xFF2E7D32),
                                          width: 2,
                                        )
                                      : null,
                                  boxShadow: isDark
                                      ? []
                                      : [
                                          BoxShadow(
                                            color: Colors.grey.withOpacity(0.1),
                                            blurRadius: 5,
                                            offset: const Offset(0, 2),
                                          ),
                                        ],
                                ),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 8,
                                  ),
                                  leading: Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? const Color(
                                              0xFF2E7D32,
                                            ).withOpacity(isDark ? 0.4 : 0.2)
                                          : (isDark
                                                ? AppColors.accentOrangeDark
                                                : Colors.orange.shade50),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      isSelected ? Icons.check : Icons.history,
                                      color: isSelected
                                          ? (isDark
                                                ? AppColors.successDark
                                                : const Color(0xFF2E7D32))
                                          : (isDark
                                                ? AppColors.warningDark
                                                : Colors.orange),
                                      size: 20,
                                    ),
                                  ),
                                  title: Text(
                                    displayName,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: isSelected
                                          ? (isDark
                                                ? AppColors.successDark
                                                : const Color(0xFF2E7D32))
                                          : textColor,
                                    ),
                                  ),
                                  trailing: Icon(
                                    Icons.arrow_forward_ios,
                                    size: 14,
                                    color: isSelected
                                        ? (isDark
                                              ? AppColors.successDark
                                              : const Color(0xFF2E7D32))
                                        : subTextColor,
                                  ),
                                  onTap: () {
                                    // 실시간 모드 중지 후 파일 로드
                                    if (_isRealtimeMode) {
                                      _stopRealtimeStream();
                                    }
                                    _loadAndDrawPath(file, fileIndex);
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
