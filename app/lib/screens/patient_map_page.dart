import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../theme_state.dart'; // ✅ [추가] 다크모드 지원

class PatientMapPage extends StatefulWidget {
  const PatientMapPage({super.key});

  @override
  State<PatientMapPage> createState() => _PatientMapPageState();
}

class _PatientMapPageState extends State<PatientMapPage> {
  NaverMapController? _mapController;
  StreamSubscription<Position>? _positionStreamSubscription;

  String _distanceText = "위치를 찾는 중...";
  NLatLng? _homeLocation;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHomeAndStartTracking();
  }

  @override
  void dispose() {
    _positionStreamSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadHomeAndStartTracking() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user != null) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();

        if (doc.exists) {
          // ✅ homeLat/homeLng 또는 homeLatitude/homeLongitude 사용
          final data = doc.data()!;
          final double? lat =
              data['homeLat']?.toDouble() ?? data['homeLatitude']?.toDouble();
          final double? lng =
              data['homeLng']?.toDouble() ?? data['homeLongitude']?.toDouble();

          if (lat != null && lng != null && lat != 0 && lng != 0) {
            setState(() {
              _homeLocation = NLatLng(lat, lng);
            });
            _startLiveTracking();
          } else {
            setState(() {
              _distanceText = "설정된 집 위치가 없습니다.";
              _isLoading = false;
            });
          }
        } else {
          setState(() {
            _distanceText = "설정된 집 위치가 없습니다.";
            _isLoading = false;
          });
        }
      } catch (e) {
        debugPrint("집 위치 로드 실패: $e");
        setState(() {
          _distanceText = "정보를 불러올 수 없습니다.";
          _isLoading = false;
        });
      }
    } else {
      setState(() {
        _distanceText = "로그인 정보가 없습니다.";
        _isLoading = false;
      });
    }
  }

  void _startLiveTracking() {
    _positionStreamSubscription?.cancel();

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    );

    _positionStreamSubscription =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
          (Position position) {
            _updateUI(position);
          },
          onError: (e) {
            debugPrint("위치 추적 에러: $e");
            if (mounted) {
              setState(() => _distanceText = "위치를 찾을 수 없습니다.");
            }
          },
        );
  }

  void _updateUI(Position position) {
    if (_homeLocation == null || !mounted) return;

    double distanceInMeters = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      _homeLocation!.latitude,
      _homeLocation!.longitude,
    );

    setState(() {
      if (distanceInMeters < 50) {
        _distanceText = "현재 집에 계십니다. 🏠";
      } else if (distanceInMeters < 1000) {
        _distanceText =
            "집에서 약 ${distanceInMeters.toStringAsFixed(0)}m\n떨어져 있습니다.";
      } else {
        _distanceText =
            "집에서 약 ${(distanceInMeters / 1000).toStringAsFixed(1)}km\n떨어져 있습니다.";
      }
      _isLoading = false;
    });

    _fitCameraToPoints(
      NLatLng(position.latitude, position.longitude),
      _homeLocation!,
    );
  }

  void _fitCameraToPoints(NLatLng p1, NLatLng p2) {
    if (_mapController == null) return;

    double minLat = (p1.latitude < p2.latitude) ? p1.latitude : p2.latitude;
    double maxLat = (p1.latitude > p2.latitude) ? p1.latitude : p2.latitude;
    double minLng = (p1.longitude < p2.longitude) ? p1.longitude : p2.longitude;
    double maxLng = (p1.longitude > p2.longitude) ? p1.longitude : p2.longitude;

    final bounds = NLatLngBounds(
      southWest: NLatLng(minLat, minLng),
      northEast: NLatLng(maxLat, maxLng),
    );

    // 1. 기존 오버레이 초기화
    _mapController!.clearOverlays();

    // 2. '집' 마커만 추가
    final homeMarker = NMarker(
      id: 'home',
      position: _homeLocation!,
      caption: const NOverlayCaption(text: "우리집", color: Colors.green),
      iconTintColor: Colors.green,
    );
    _mapController!.addOverlay(homeMarker);

    // 3. 카메라 이동
    try {
      _mapController!.updateCamera(
        NCameraUpdate.fitBounds(bounds, padding: const EdgeInsets.all(100)),
      );
    } catch (e) {}
  }

  @override
  Widget build(BuildContext context) {
    // ✅ [개선] 다크모드 지원
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? AppColors.darkBackground : Colors.white;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black87;
    final subTextColor = isDark ? AppColors.darkOnSurfaceVariant : Colors.grey;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Text(
          "집과의 거리",
          style: TextStyle(fontWeight: FontWeight.bold, color: textColor),
        ),
        backgroundColor: backgroundColor,
        foregroundColor: textColor,
        elevation: 0,
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            flex: 7,
            child: Stack(
              children: [
                NaverMap(
                  options: const NaverMapViewOptions(
                    locationButtonEnable: true,
                    tiltGesturesEnable: false,
                    rotationGesturesEnable: false,
                  ),
                  onMapReady: (controller) {
                    _mapController = controller;

                    // 🔥 [핵심 수정 포인트]
                    // 1. 위치 오버레이(파란 점)를 보이게 설정
                    final locationOverlay = _mapController!
                        .getLocationOverlay();
                    locationOverlay.setIsVisible(true);

                    // 2. 🔥 트래킹 모드를 'NoFollow'로 설정해서 강제로 위치 추적 시작!
                    // (이게 있어야 버튼 안 눌러도 파란 점이 바로 뜸)
                    _mapController!.setLocationTrackingMode(
                      NLocationTrackingMode.noFollow,
                    );
                  },
                ),
                if (_isLoading)
                  Container(
                    color: Colors.black12,
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.green),
                    ),
                  ),
              ],
            ),
          ),

          Expanded(
            flex: 3,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkSurface : Colors.white,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(30),
                ),
                boxShadow: isDark
                    ? []
                    : [
                        const BoxShadow(
                          color: Colors.black12,
                          blurRadius: 15,
                          offset: Offset(0, -5),
                        ),
                      ],
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.home_rounded,
                      color: isDark ? AppColors.successDark : Colors.green,
                      size: 36,
                    ),
                    const SizedBox(height: 10),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _distanceText,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: textColor,
                          height: 1.2,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (!_isLoading)
                      Text(
                        "위치는 실시간으로 업데이트됩니다.",
                        style: TextStyle(fontSize: 13, color: subTextColor),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
