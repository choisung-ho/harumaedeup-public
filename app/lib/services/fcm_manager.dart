// lib/services/fcm_manager.dart

import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart'; // ✅ 추가됨
import 'package:flutter_tts/flutter_tts.dart'; // ✅ [추가] 이동 알림 음성 안내용
import 'package:my_first_app/services/fcm_token_sync_service.dart'; // ✅ 토큰 동기화 서비스
import 'package:my_first_app/screens/medication_fullscreen_page.dart'; // ✅ 전체화면 약 알림
import 'package:my_first_app/screens/guardian_map_page.dart'; // ✅ 위치 보기 화면

class FCMManager {
  // ✅ 네비게이터 키 (main.dart에서 설정)
  static GlobalKey<NavigatorState>? navigatorKey;
  static final FCMManager _instance = FCMManager._internal();
  factory FCMManager() => _instance;
  FCMManager._internal();

  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  // ✅ 로컬 알림 플러그인 추가
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  // ✅ FCM 토큰 동기화 서비스
  final FcmTokenSyncService _tokenSyncService = FcmTokenSyncService();
  // ✅ [추가] 이동 알림 TTS 인스턴스 (AI 음성비서와 별개)
  final FlutterTts _travelTts = FlutterTts();

  // 서버 주소
  final String _serverUrl = 'http://endpoint-3.example.invalid:8000/update-token';

  Future<void> init() async {
    // 1. 알림 권한 요청
    NotificationSettings settings = await _firebaseMessaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      debugPrint('🔔 알림 권한 허용됨');

      // 2. FCM 토큰 처리 (서버 전송)
      String? fcmToken = await _firebaseMessaging.getToken();
      if (fcmToken != null) {
        debugPrint("🔥 FCM Token: $fcmToken");
        await _sendTokenToServer(fcmToken);
      }

      // ✅ 3. FCM 토큰 동기화 서비스 초기화 (보호자-시니어 토큰 자동 동기화)
      await _tokenSyncService.init();

      _firebaseMessaging.onTokenRefresh.listen((newToken) {
        _sendTokenToServer(newToken);
        // ✅ 토큰 갱신 시 연결된 상대방에게도 자동 동기화됨 (FcmTokenSyncService에서 처리)
      });

      // ✅ 4. 로컬 알림 초기화 (버튼 표시를 위해 필수)
      await _initLocalNotifications();

      // ✅ 5. 이동 알림 TTS 초기화 (AI 음성비서와 별개 - 시스템 TTS 볼륨 사용)
      await _travelTts.setLanguage("ko-KR");
      await _travelTts.setSpeechRate(0.5); // 천천히 또박또박 읽기
      await _travelTts.setVolume(1.0);
      await _travelTts.setPitch(1.0);

      // ✅ 6. 앱이 켜져있을 때(Foreground) 메시지 수신 리스너
      FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
        debugPrint(
          '📩 FCM 메시지 수신: ${message.notification?.title} / 데이터: ${message.data}',
        );
        debugPrint('📩 [DEBUG] 전체 data 필드: ${message.data}');

        final String? messageType = message.data['type'];
        debugPrint('📩 [DEBUG] 메시지 타입: $messageType');

        // ✅ [수정] 긴급 이탈 알림 처리 (포그라운드 - 보호자 모드에서만 동작)
        if (messageType == 'emergency') {
          final prefs = await SharedPreferences.getInstance();
          final savedUid = prefs.getString('currentUser');
          dynamic rawRole =
              prefs.get('role') ?? prefs.get('user_role_$savedUid') ?? '0';
          String role = rawRole.toString();

          if (role == '1') {
            debugPrint('🚨 긴급 이탈 알림 감지! (보호자 모드) 알림 표시...');
            _handleEmergencyAlert(message);
          } else {
            debugPrint('🚫 [포그라운드] 시니어 모드에서 긴급 알림 차단됨');
          }
        }
        // ✅ [A] 이동 출발 알림 (Travel Reminder) 처리
        // 서버에서 보내는 다양한 타입명 호환
        else if (_isTravelReminderType(messageType)) {
          debugPrint('🚶 이동 알림 감지! TTS 실행 시도...');
          _handleTravelAlert(message);
        }
        // ✅ [B] 약 복용 알림 처리
        else if (_isMedicationType(messageType)) {
          debugPrint('🔔 약 복용 알림 감지! 전체화면 표시 시도...');
          _showMedicationFullscreen(message);
        }
        // ✅ [C] 그 외 일반 알림
        else {
          _showNotification(message);
        }
      });

      // ✅ 7. 앱이 백그라운드에서 알림 클릭 시 처리
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('📩 FCM 백그라운드 알림 클릭: ${message.data}');
        final String? messageType = message.data['type'];

        // ✅ [추가] 긴급 이탈 알림 클릭 시 보호자 홈으로 이동
        if (messageType == 'emergency') {
          _navigateToGuardianHome(message);
        }
        // ✅ 이동 알림 클릭 시 TTS 실행
        else if (_isTravelReminderType(messageType)) {
          _handleTravelAlert(message);
        } else if (_isMedicationType(messageType)) {
          _showMedicationFullscreen(message);
        }
      });

      // ✅ 8. 앱이 종료된 상태에서 알림 클릭으로 열린 경우
      RemoteMessage? initialMessage = await _firebaseMessaging
          .getInitialMessage();
      if (initialMessage != null) {
        debugPrint('📩 FCM 초기 메시지: ${initialMessage.data}');
        final String? messageType = initialMessage.data['type'];

        // ✅ [추가] 긴급 이탈 알림으로 앱 시작된 경우
        if (messageType == 'emergency') {
          Future.delayed(const Duration(milliseconds: 500), () {
            _navigateToGuardianHome(initialMessage);
          });
        }
        // ✅ 이동 알림으로 앱 실행된 경우 TTS 실행
        else if (_isTravelReminderType(messageType)) {
          Future.delayed(const Duration(milliseconds: 500), () {
            _handleTravelAlert(initialMessage);
          });
        } else if (_isMedicationType(messageType)) {
          // 약간의 딜레이 후 전체화면 표시 (앱 초기화 대기)
          Future.delayed(const Duration(milliseconds: 500), () {
            _showMedicationFullscreen(initialMessage);
          });
        }
      }
    } else {
      debugPrint('🔕 알림 권한 거부됨');
    }
  }

  // ✅ [추가] 약 복용 알림 타입인지 확인하는 헬퍼 함수
  bool _isMedicationType(String? type) {
    if (type == null) return false;
    return type == 'medication' ||
        type == 'medication_alert' ||
        type == 'medication_alarm';
  }

  // ✅ [추가] 이동 출발 알림 타입인지 확인하는 헬퍼 함수
  // 서버에서 보낼 수 있는 다양한 타입명 호환
  bool _isTravelReminderType(String? type) {
    if (type == null) return false;
    final lowerType = type.toLowerCase();
    return lowerType == 'travel_reminder' ||
        lowerType == 'travel' ||
        lowerType == 'schedule_reminder' ||
        lowerType == 'schedule' ||
        lowerType == 'departure' ||
        lowerType == 'departure_reminder' ||
        lowerType == 'location_reminder' ||
        lowerType == 'appointment' ||
        lowerType == 'appointment_reminder';
  }

  // ✅ [핵심] 전체 화면 약 복용 다이얼로그 표시
  void _showMedicationFullscreen(RemoteMessage message) {
    if (navigatorKey?.currentState == null) {
      debugPrint('⚠️ Navigator가 준비되지 않음 - 로컬 알림으로 대체');
      _showMedicationNotification(message);
      return;
    }

    // ✅ Cloud Functions에서 보내는 필드명 호환 (alarm_id 또는 medicine_id)
    final String? alarmId =
        message.data['alarm_id'] ?? message.data['medicine_id'];
    final String? medicationName = message.data['medication_name'];
    final String? title = message.notification?.title ?? message.data['title'];
    final String? body = message.notification?.body ?? message.data['body'];

    // ✅ 재시도 횟수 가져오기 (FastAPI 서버에서 보내는 값)
    // retry_count가 "1" 이상이면 미복용으로 인한 재알림
    final int retryCount =
        int.tryParse(message.data['retry_count'] ?? '0') ?? 0;

    // ✅ [추가] 재알림 여부 로깅 (백엔드 구분용)
    final bool isRetryAlarm = retryCount > 0;
    if (isRetryAlarm) {
      debugPrint('⚠️ [재알림] $retryCount번째 미복용 알림입니다!');
    }

    debugPrint(
      '🔔 전체화면 약 알림 표시: $medicationName (alarmId: $alarmId, retryCount: $retryCount, isRetry: $isRetryAlarm)',
    );

    navigatorKey!.currentState!.push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => MedicationFullscreenPage(
          alarmId: alarmId,
          medicationName: medicationName,
          title: title,
          body: body,
          retryCount: retryCount,
        ),
      ),
    );
  }

  // ✅ 로컬 알림 초기화 함수
  Future<void> _initLocalNotifications() async {
    const AndroidInitializationSettings android = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const DarwinInitializationSettings ios = DarwinInitializationSettings();
    const InitializationSettings settings = InitializationSettings(
      android: android,
      iOS: ios,
    );

    await _localNotifications.initialize(settings);
  }

  // ✅ [핵심] 약 복용 알림 표시 (복용 완료 버튼 포함)
  Future<void> _showMedicationNotification(RemoteMessage message) async {
    // ✅ [추가] 메시지 데이터에서 정보 추출
    final String? alarmId =
        message.data['alarm_id'] ?? message.data['medicine_id'];
    final String? medicationName = message.data['medication_name'];
    final String retryCount = message.data['retry_count'] ?? '0';

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'medication_fullscreen_channel', // ✅ [수정] 전체화면 채널로 변경
          '약 복용 알림', // 채널 이름
          channelDescription: '약 복용 시간 알림입니다.',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          fullScreenIntent: true, // ✅ [추가] 전체화면 인텐트 활성화
          category: AndroidNotificationCategory.alarm, // ✅ [추가] 알람 카테고리
          enableVibration: true,
          // 🔥 '복용 완료' 버튼 추가 부분
          actions: <AndroidNotificationAction>[
            const AndroidNotificationAction(
              'TAKE_MEDICATION', // 버튼 ID (main.dart에서 이 ID를 확인하여 처리함)
              '💊 복용 완료', // 버튼에 표시될 텍스트
              showsUserInterface: true,
              cancelNotification: true,
            ),
            const AndroidNotificationAction(
              'SKIP_MEDICATION', // ✅ [추가] 미복용 버튼
              '⏰ 나중에',
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ],
        );

    await _localNotifications.show(
      999, // 약 알림 ID 고정 (또는 message.hashCode 사용)
      '💊 ${message.notification?.title ?? "약 드실 시간"}',
      message.notification?.body ?? "약 드실 시간입니다!",
      NotificationDetails(
        android: androidDetails,
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
        ),
      ),
      // ✅ [수정] payload에 모든 정보 포함 (클릭 시 전체화면 이동용)
      payload: 'medication|$alarmId|$medicationName|$retryCount',
    );
  }

  // ✅ 일반 알림 표시
  Future<void> _showNotification(RemoteMessage message) async {
    await _localNotifications.show(
      message.hashCode,
      message.notification?.title ?? '알림',
      message.notification?.body ?? '',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'default_channel',
          '기본 알림',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }

  // ✅ [추가] 긴급 이탈 알림 처리 (포그라운드)
  Future<void> _handleEmergencyAlert(RemoteMessage message) async {
    final String patientName = message.data['patientName'] ?? '대상자';
    final String alertMessage =
        message.data['alertMessage'] ?? '안전 구역을 벗어났습니다!';
    final String title =
        message.notification?.title ?? '🚨 비상: $patientName님 이탈';
    final String body = message.notification?.body ?? alertMessage;
    final String patientId = message.data['patientId'] ?? '';

    debugPrint('🚨 [긴급알림] 포그라운드 처리: $title');

    // 로컬 알림 표시 (포그라운드에서도 헤드업 알림 표시)
    const androidDetails = AndroidNotificationDetails(
      'emergency_channel_id',
      '긴급 이탈 알림',
      channelDescription: '환자가 안전 구역을 벗어났을 때 울립니다.',
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      enableVibration: true,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: true,
      visibility: NotificationVisibility.public,
      color: Colors.red,
    );

    await _localNotifications.show(
      777,
      title,
      body,
      const NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
      ),
      payload: 'emergency|$patientId|$patientName',
    );
  }

  // ✅ [수정] 긴급 알림 클릭 시 위치 보기 화면으로 이동
  void _navigateToGuardianHome(RemoteMessage message) {
    if (navigatorKey?.currentState == null) {
      debugPrint('⚠️ Navigator가 준비되지 않음');
      return;
    }

    final String? patientId = message.data['patientId'];
    final String patientName = message.data['patientName'] ?? '대상자';
    debugPrint('🚨 [긴급알림] 위치 보기 화면으로 이동. patientId: $patientId');

    if (patientId != null && patientId.isNotEmpty) {
      navigatorKey!.currentState!.push(
        MaterialPageRoute(
          builder: (context) =>
              GuardianMapPage(patientId: patientId, patientName: patientName),
        ),
      );
    } else {
      navigatorKey!.currentState!.pushNamedAndRemoveUntil(
        '/guardian_home',
        (route) => false,
        arguments: {'patientId': patientId},
      );
    }
  }

  // ✅ [신규] 이동 출발 알림 처리 및 음성 안내
  Future<void> _handleTravelAlert(RemoteMessage message) async {
    String title =
        message.notification?.title ?? message.data['title'] ?? "출발 알림";
    String body =
        message.notification?.body ??
        message.data['body'] ??
        "약속 장소로 출발할 시간입니다.";

    // 서버에서 보내준 'speech' 데이터가 있으면 그걸 읽고, 없으면 본문(body)을 읽음
    String speechText = message.data['speech'] ?? body;

    debugPrint('🚶 [TTS] 이동 알림 처리 시작');
    debugPrint('🚶 [TTS] title: $title');
    debugPrint('🚶 [TTS] body: $body');
    debugPrint('🚶 [TTS] speechText: $speechText');

    // (1) 화면에 알림 표시 (Heads-up Notification)
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'travel_alert_channel', // 채널 ID
          '이동 출발 알림', // 채널 이름
          channelDescription: '일정 시간에 맞춰 출발 알림을 보냅니다.',
          importance: Importance.max,
          priority: Priority.high,
          fullScreenIntent: true, // 화면 깨우기
          ticker: '지금 출발하셔야 해요!',
        );

    await _localNotifications.show(
      DateTime.now().millisecond, // 고유 ID
      title,
      body,
      const NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
      ),
    );

    debugPrint('🚶 [TTS] 로컬 알림 표시 완료, TTS 실행 대기...');

    // (2) 음성으로 읽어주기 (TTS)
    // 딜레이를 살짝 주어 알림 소리와 겹치지 않게 함
    Future.delayed(const Duration(milliseconds: 800), () async {
      debugPrint('🔊 [TTS] speak() 호출 시작: $speechText');
      try {
        // TTS 상태 확인 및 재설정
        await _travelTts.setLanguage("ko-KR");
        await _travelTts.setSpeechRate(0.5);
        await _travelTts.setVolume(1.0);

        final result = await _travelTts.speak(speechText);
        debugPrint('🔊 [TTS] speak() 결과: $result');
      } catch (e) {
        debugPrint('❌ [TTS] 오류 발생: $e');
      }
    });
  }

  // 기존 서버 토큰 전송 로직 (사용자님 코드 유지)
  Future<void> _sendTokenToServer(String fcmToken) async {
    try {
      User? user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint("❌ 로그인된 유저가 없어 토큰 전송 실패");
        return;
      }

      String? idToken = await user.getIdToken();
      if (idToken == null) return;

      debugPrint("🚀 서버로 FCM 토큰 전송 시도...");

      final response = await http.post(
        Uri.parse(_serverUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $idToken',
        },
        body: jsonEncode({'token': fcmToken}),
      );

      if (response.statusCode == 200) {
        debugPrint("✅ FCM 토큰 서버 등록 성공!");
      } else {
        debugPrint("❌ FCM 토큰 등록 실패: ${response.statusCode} - ${response.body}");
      }
    } catch (e) {
      debugPrint("❌ FCM 전송 중 에러: $e");
    }
  }
}
