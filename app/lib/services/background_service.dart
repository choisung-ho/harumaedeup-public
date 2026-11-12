import 'dart:async';
import 'dart:ui';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';

// ✅ 기존 및 신규 서비스 임포트
// (파일 경로가 다르면 본인 프로젝트에 맞게 수정해주세요)
import 'safety_monitor_service.dart'; // [신규] 지오펜싱
import 'location_service.dart';
import 'auto_upload_service.dart';
import '../firebase_options.dart'; // firebase_options.dart가 있다면

// -----------------------------------------------------------------------------
// 1. [Android] 백그라운드 메인 로직 (엔트리 포인트)
// -----------------------------------------------------------------------------
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  // 플러그인 초기화
  DartPluginRegistrant.ensureInitialized();

  // Firebase 초기화
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
  } catch (e) {
    debugPrint("Background Firebase Init Error: $e");
  }

  // 기존 위치 서비스 초기화
  await LocationService.initialize();

  // 알림 플러그인 설정
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // 서비스 이벤트 리스너 (포그라운드/백그라운드 전환)
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // ---------------------------------------------------------------------------
  // 🚀 [기능 1] 안전 구역(지오펜싱) 감시 시작
  // ✅ [수정됨] FirebaseAuth에서 직접 UID 가져오기 + SharedPreferences fallback
  // ---------------------------------------------------------------------------
  final prefs = await SharedPreferences.getInstance();

  // Firebase Auth에서 현재 로그인된 사용자 UID 가져오기
  String? patientId = FirebaseAuth.instance.currentUser?.uid;

  // Auth에서 못 가져오면 SharedPreferences에서 가져오기
  if (patientId == null || patientId.isEmpty) {
    patientId = prefs.getString('current_patient_id');
  }

  // 역할 확인 (시니어만 지오펜싱 감시)
  final String? role = patientId != null
      ? (prefs.getString('user_role_$patientId') ?? prefs.getString('role'))
      : null;

  if (patientId != null && (role == '2' || role == '2.0')) {
    debugPrint("🚀 [Background] 시니어 ID($patientId) 지오펜싱 감시 시작");
    SafetyMonitorService().startMonitoring(patientId);
  } else {
    debugPrint(
      "⚠️ [Background] 시니어가 아니거나 환자 ID 없음. 지오펜싱 대기 중. (patientId: $patientId, role: $role)",
    );
  }

  // ---------------------------------------------------------------------------
  // 🔄 [기능 2] 자동 업로드 스캔 (5분 주기)
  // ---------------------------------------------------------------------------
  Timer.periodic(const Duration(minutes: 5), (timer) async {
    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid ?? patientId;

      if (currentUid != null) {
        // SharedPreferences를 새로 불러와야 최신 상태 확인 가능
        final p = await SharedPreferences.getInstance();
        final role = p.getString('user_role_$currentUid');

        if (role == '2') {
          // 시니어 모드일 때만
          debugPrint("🔄 [Background] 자동 업로드 스캔...");
          await AutoUploadService().scanAndUploadAll();
        }
      }
    } catch (e) {
      debugPrint("⚠️ [Background] 자동 업로드 오류: $e");
    }
  });

  // ---------------------------------------------------------------------------
  // 📍 [기능 3] 이동 경로 저장 (아카이브용)
  // ---------------------------------------------------------------------------
  Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 15,
    ),
  ).listen((Position position) async {
    // 정확도가 너무 낮으면(오차 50m 이상) 무시
    if (position.accuracy > 50.0) return;
    await LocationService.saveLocationForArchive(position);
  });

  // ---------------------------------------------------------------------------
  // 🔔 상단바 알림 유지 (죽지 않게 함)
  // ---------------------------------------------------------------------------
  if (service is AndroidServiceInstance) {
    if (await service.isForegroundService()) {
      flutterLocalNotificationsPlugin.show(
        888,
        '하루 매듭 안전 지킴이',
        '안전하게 보호하고 있습니다.', // 문구 변경 가능
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'my_foreground',
            '하루매듭 서비스',
            icon: 'ic_bg_service_small', // 아이콘 없으면 @mipmap/ic_launcher
            ongoing: true,
          ),
        ),
      );
    }
  }
}

// -----------------------------------------------------------------------------
// 2. [iOS] 껍데기 함수 (타입 에러 방지용)
// -----------------------------------------------------------------------------
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

// -----------------------------------------------------------------------------
// 3. 서비스 초기화 및 설정 (main.dart에서 호출)
// -----------------------------------------------------------------------------
Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  // 안드로이드 알림 채널 생성
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'my_foreground',
    '하루매듭 서비스',
    description: '하루매듭 백그라운드 서비스가 실행 중입니다',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  if (Platform.isAndroid) {
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
  }

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart, // 실행 함수 연결
      autoStart: false, // ✅ 로그인 후 수동 시작 추천
      isForegroundMode: true, // 포그라운드 모드 (잘 안 죽음)
      notificationChannelId: 'my_foreground',
      initialNotificationTitle: '🌟 하루매듭',
      initialNotificationContent: '서비스 준비 중...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground, // ✅ Future<bool> 반환 함수 연결 (오류 해결)
    ),
  );
}
