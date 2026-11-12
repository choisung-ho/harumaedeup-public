// guardian_monitor_service.dart
// ✅ [수정됨] users 컬렉션의 status 필드를 감시하도록 변경

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

class GuardianMonitorService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static String? _lastStatus;

  /// 시니어 상태 감시 시작 (보호자 앱에서 호출)
  static void startMonitoring(String patientDocId) {
    debugPrint("==========================================");
    debugPrint("👀 [GuardianMonitor] 시니어 상태 감시 시작: $patientDocId");
    debugPrint("==========================================");

    _initializeNotifications();

    // ✅ [수정] users 컬렉션의 status 필드 감시
    FirebaseFirestore.instance
        .collection('users')
        .doc(patientDocId)
        .snapshots()
        .listen(
          (snapshot) {
            // 1. 문서가 아예 없는 경우
            if (!snapshot.exists) {
              debugPrint(
                "❌ [GuardianMonitor] 해당 ID($patientDocId)의 데이터가 DB에 없습니다!",
              );
              return;
            }

            // 2. 데이터가 있는 경우
            final data = snapshot.data();
            if (data != null) {
              final String status = data['status'] ?? 'safe';
              final String alertMessage =
                  data['alertMessage'] ?? '안전 구역을 벗어났습니다!';
              final String patientName = data['name'] ?? '대상자';

              debugPrint(
                "📡 [GuardianMonitor] 상태 수신: $status | 환자: $patientName | 메시지: $alertMessage",
              );

              // 상태가 'emergency'이고 이전 상태와 다른 경우에만 알림
              if (status == 'emergency' && _lastStatus != 'emergency') {
                debugPrint("🚨 [GuardianMonitor] 비상 상태 감지! 로컬 알림 발송");
                _showEmergencyNotification(patientName, alertMessage);
              }

              _lastStatus = status;
            }
          },
          onError: (e) {
            debugPrint("❌ [GuardianMonitor] 데이터 수신 오류: $e");
          },
        );
  }

  static Future<void> _initializeNotifications() async {
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
    );
    await _notificationsPlugin.initialize(initSettings);

    // [✅] 안드로이드 13 이상을 위한 권한 요청 (필수)
    final androidImplementation = _notificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidImplementation?.requestNotificationsPermission();

    // ✅ [추가] 긴급 알림 채널 생성
    const emergencyChannel = AndroidNotificationChannel(
      'emergency_channel_id',
      '긴급 이탈 알림',
      description: '환자가 안전 구역을 벗어났을 때 울립니다.',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );
    await androidImplementation?.createNotificationChannel(emergencyChannel);
  }

  static Future<void> _showEmergencyNotification(
    String patientName,
    String message,
  ) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'emergency_channel_id',
          '긴급 이탈 알림',
          channelDescription: '환자가 안전 구역을 벗어났을 때 울립니다.',
          importance: Importance.max,
          priority: Priority.max,
          color: Colors.red,
          playSound: true,
          enableVibration: true,
          category: AndroidNotificationCategory.alarm,
          fullScreenIntent: true,
          visibility: NotificationVisibility.public,
        );

    await _notificationsPlugin.show(
      777,
      '🚨 비상: $patientName님 이탈!',
      message,
      const NotificationDetails(android: androidDetails),
      payload: 'emergency', // 클릭 시 앱 이동용
    );
  }
}
