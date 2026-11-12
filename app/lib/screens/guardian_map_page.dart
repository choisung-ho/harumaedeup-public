import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../theme_state.dart'; // 테마 시스템

/// 보호자 모드 - 시니어의 현재 위치와 집과의 거리를 실시간으로 표시하는 페이지
class GuardianMapPage extends StatefulWidget {
  final String patientId;
  final String patientName;

  const GuardianMapPage({
    super.key,
    required this.patientId,
    required this.patientName,
  });

  @override
  State<GuardianMapPage> createState() => _GuardianMapPageState();
}

class _GuardianMapPageState extends State<GuardianMapPage> {
  NaverMapController? _mapController;
  StreamSubscription<DocumentSnapshot>? _patientSub;

  String _distanceText = "위치를 찾는 중...";
  NLatLng? _homeLocation;
  NLatLng? _patientLocation;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _subscribePatientData();
  }

  @override
  void dispose() {
    // 네이버 지도 위치 추적 종료
    _mapController?.setLocationTrackingMode(NLocationTrackingMode.none);
    _patientSub?.cancel();
    debugPrint("🧹 GuardianMapPage 자원 정리 완료");
    super.dispose();
  }

  /// Firestore에서 시니어의 위치 및 집 위치 실시간 구독
  void _subscribePatientData() {
    _patientSub = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.patientId)
        .snapshots()
        .listen(
          (snapshot) {
            if (!snapshot.exists || !mounted) return;

            final data = snapshot.data();
            if (data == null) return;

            // 시니어의 현재 위치 (currentLat, currentLng)
            final double? currentLat = data['currentLat']?.toDouble();
            final double? currentLng = data['currentLng']?.toDouble();

            // 시니어의 집 위치 (homeLat, homeLng 또는 homeLatitude, homeLongitude)
            final double? homeLat =
                data['homeLat']?.toDouble() ?? data['homeLatitude']?.toDouble();
            final double? homeLng =
                data['homeLng']?.toDouble() ??
                data['homeLongitude']?.toDouble();

            setState(() {
              // 집 위치 설정
              if (homeLat != null &&
                  homeLng != null &&
                  homeLat != 0 &&
                  homeLng != 0) {
                _homeLocation = NLatLng(homeLat, homeLng);
              }

              // 시니어 현재 위치 설정
              if (currentLat != null &&
                  currentLng != null &&
                  currentLat != 0 &&
                  currentLng != 0) {
                _patientLocation = NLatLng(currentLat, currentLng);
              }

              _isLoading = false;
            });

            _updateDistanceText();
            _updateMapOverlays();
          },
          onError: (e) {
            debugPrint("❌ 시니어 데이터 구독 오류: $e");
            if (mounted) {
              setState(() {
                _distanceText = "정보를 불러올 수 없습니다.";
                _isLoading = false;
              });
            }
          },
        );
  }

  /// 거리 텍스트 업데이트
  void _updateDistanceText() {
    if (_homeLocation == null) {
      setState(
        () => _distanceText = "${widget.patientName}님의 집 위치가 설정되지 않았습니다.",
      );
      return;
    }

    if (_patientLocation == null) {
      setState(() => _distanceText = "${widget.patientName}님의 위치를 찾는 중...");
      return;
    }

    // 거리 계산 (미터 단위) - Haversine 공식
    final double distanceInMeters = _calculateDistance(
      _patientLocation!.latitude,
      _patientLocation!.longitude,
      _homeLocation!.latitude,
      _homeLocation!.longitude,
    );

    setState(() {
      if (distanceInMeters < 50) {
        _distanceText = "${widget.patientName}님이\n현재 집에 계십니다. 🏠";
      } else if (distanceInMeters < 1000) {
        _distanceText =
            "${widget.patientName}님이\n집에서 약 ${distanceInMeters.toStringAsFixed(0)}m\n떨어져 있습니다.";
      } else {
        _distanceText =
            "${widget.patientName}님이\n집에서 약 ${(distanceInMeters / 1000).toStringAsFixed(1)}km\n떨어져 있습니다.";
      }
    });
  }

  /// 두 좌표 간 거리 계산 (Haversine 공식)
  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double earthRadius = 6371000; // 지구 반지름 (미터)
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

  /// 지도 오버레이 업데이트 (시니어 위치 + 집 위치)
  void _updateMapOverlays() {
    if (_mapController == null) return;

    _mapController!.clearOverlays();

    // 집 마커
    if (_homeLocation != null) {
      final homeMarker = NMarker(
        id: 'home',
        position: _homeLocation!,
        caption: const NOverlayCaption(text: "집", color: Colors.green),
        iconTintColor: Colors.green,
      );
      _mapController!.addOverlay(homeMarker);
    }

    // 시니어 현재 위치 마커
    if (_patientLocation != null) {
      final patientMarker = NMarker(
        id: 'patient',
        position: _patientLocation!,
        caption: NOverlayCaption(text: widget.patientName, color: Colors.red),
        iconTintColor: Colors.red,
      );
      _mapController!.addOverlay(patientMarker);
    }

    // 둘 다 있으면 카메라 이동
    if (_homeLocation != null && _patientLocation != null) {
      _fitCameraToPoints(_patientLocation!, _homeLocation!);
    } else if (_patientLocation != null) {
      _mapController!.updateCamera(
        NCameraUpdate.scrollAndZoomTo(target: _patientLocation!, zoom: 15),
      );
    } else if (_homeLocation != null) {
      _mapController!.updateCamera(
        NCameraUpdate.scrollAndZoomTo(target: _homeLocation!, zoom: 15),
      );
    }
  }

  /// 두 지점을 모두 포함하도록 카메라 이동
  void _fitCameraToPoints(NLatLng p1, NLatLng p2) {
    double minLat = (p1.latitude < p2.latitude) ? p1.latitude : p2.latitude;
    double maxLat = (p1.latitude > p2.latitude) ? p1.latitude : p2.latitude;
    double minLng = (p1.longitude < p2.longitude) ? p1.longitude : p2.longitude;
    double maxLng = (p1.longitude > p2.longitude) ? p1.longitude : p2.longitude;

    final bounds = NLatLngBounds(
      southWest: NLatLng(minLat, minLng),
      northEast: NLatLng(maxLat, maxLng),
    );

    try {
      _mapController!.updateCamera(
        NCameraUpdate.fitBounds(bounds, padding: const EdgeInsets.all(100)),
      );
    } catch (e) {
      debugPrint("카메라 이동 오류: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? AppColors.darkBackground : Colors.white;
    final surfaceColor = isDark ? AppColors.darkSurface : Colors.white;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black87;
    final subtextColor = isDark ? AppColors.darkOnSurfaceVariant : Colors.grey;
    final shadowColor = isDark ? Colors.black26 : Colors.black12;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Text(
          "${widget.patientName}님 위치",
          style: TextStyle(fontWeight: FontWeight.bold, color: textColor),
        ),
        backgroundColor: backgroundColor,
        foregroundColor: textColor,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: textColor),
      ),
      body: Column(
        children: [
          // 지도 영역 (Flexible로 남은 공간 차지)
          Flexible(
            flex: 1,
            child: Stack(
              children: [
                NaverMap(
                  options: const NaverMapViewOptions(
                    locationButtonEnable: false, // 보호자 위치 버튼 비활성화
                    tiltGesturesEnable: false,
                    rotationGesturesEnable: false,
                    initialCameraPosition: NCameraPosition(
                      target: NLatLng(37.5665, 126.9780),
                      zoom: 14,
                    ),
                  ),
                  onMapReady: (controller) {
                    _mapController = controller;
                    _updateMapOverlays();
                  },
                ),
                if (_isLoading)
                  Container(
                    color: isDark ? Colors.black26 : Colors.black12,
                    child: Center(
                      child: CircularProgressIndicator(
                        color: isDark ? AppColors.darkPrimary : Colors.blue,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // 거리 정보 영역 - SafeArea와 LayoutBuilder로 반응형 처리
          SafeArea(
            top: false,
            child: Container(
              width: double.infinity,
              constraints: BoxConstraints(
                minHeight: MediaQuery.of(context).size.height * 0.18,
              ),
              padding: EdgeInsets.symmetric(
                horizontal: 20,
                vertical: MediaQuery.of(context).size.height * 0.025,
              ),
              decoration: BoxDecoration(
                color: surfaceColor,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(30),
                ),
                boxShadow: [
                  BoxShadow(
                    color: shadowColor,
                    blurRadius: 15,
                    offset: const Offset(0, -5),
                  ),
                ],
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final screenHeight = MediaQuery.of(context).size.height;
                  final iconSize = (screenHeight * 0.045).clamp(28.0, 40.0);
                  final titleFontSize = (screenHeight * 0.026).clamp(
                    16.0,
                    22.0,
                  );
                  final subtitleFontSize = (screenHeight * 0.016).clamp(
                    11.0,
                    14.0,
                  );
                  final spacing = (screenHeight * 0.012).clamp(6.0, 12.0);

                  return SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.location_on,
                          color: isDark ? AppColors.darkPrimary : Colors.blue,
                          size: iconSize,
                        ),
                        SizedBox(height: spacing),
                        Text(
                          _distanceText,
                          style: TextStyle(
                            fontSize: titleFontSize,
                            fontWeight: FontWeight.bold,
                            color: textColor,
                            height: 1.3,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        SizedBox(height: spacing * 0.6),
                        if (!_isLoading)
                          Text(
                            "위치는 실시간으로 업데이트됩니다.",
                            style: TextStyle(
                              fontSize: subtitleFontSize,
                              color: subtextColor,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
