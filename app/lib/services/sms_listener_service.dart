// lib/services/sms_listener_service.dart
// SMS 알림 감지 서비스 (NotificationListenerService 연동)
// Android 네이티브 코드와 연동하여 SMS 알림을 감지하고 업로드

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart'; // ✅ [추가]

import 'auto_upload_service.dart';

/// SMS 리스너 서비스
/// Android의 NotificationListenerService와 MethodChannel로 통신
class SmsListenerService {
  static const MethodChannel _channel = MethodChannel(
    'com.example.my_first_app/sms_listener',
  );

  // 싱글톤
  static final SmsListenerService _instance = SmsListenerService._internal();
  factory SmsListenerService() => _instance;
  SmsListenerService._internal();

  bool _isInitialized = false;
  final AutoUploadService _uploadService = AutoUploadService();

  /// 서비스 초기화
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // 역할 확인 - 시니어 모드만 활성화
      if (!await _canRun()) {
        debugPrint("🚫 [SmsListener] Guardian 모드 - 비활성화");
        return;
      }

      // MethodChannel 핸들러 설정
      _channel.setMethodCallHandler(_handleMethodCall);
      _isInitialized = true;
      debugPrint("✅ [SmsListener] 초기화 완료");
    } catch (e) {
      debugPrint("❌ [SmsListener] 초기화 오류: $e");
    }
  }

  /// 역할 확인 (시니어 모드 = role '2')
  Future<bool> _canRun() async {
    try {
      // ✅ [핵심 수정] FirebaseAuth에서 직접 UID 가져오기
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null) {
        debugPrint("⚠️ [SmsListener] Firebase 로그인 안됨");
        return false;
      }

      final prefs = await SharedPreferences.getInstance();
      final role = prefs.getString('user_role_$currentUid');
      debugPrint("🔍 [SmsListener] UID=$currentUid, role=$role");
      return role == '2'; // 시니어 모드만
    } catch (e) {
      return false;
    }
  }

  /// Android에서 호출되는 메서드 핸들러
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onSmsReceived':
        await _handleSmsReceived(call.arguments);
        break;
      case 'onNotificationPosted':
        await _handleNotificationPosted(call.arguments);
        break;
      default:
        debugPrint("⚠️ [SmsListener] 알 수 없는 메서드: ${call.method}");
    }
  }

  /// SMS 수신 처리
  Future<void> _handleSmsReceived(dynamic arguments) async {
    try {
      if (!await _canRun()) return;

      final Map<String, dynamic> data = Map<String, dynamic>.from(arguments);
      final sender = data['sender'] as String? ?? 'Unknown';
      final message = data['message'] as String? ?? '';
      final timestamp = DateTime.now();

      debugPrint("📱 [SmsListener] SMS 수신: $sender");

      // AutoUploadService를 통해 업로드
      await _uploadService.uploadSmsLog(
        sender: sender,
        message: message,
        timestamp: timestamp,
      );
    } catch (e) {
      debugPrint("❌ [SmsListener] SMS 처리 오류: $e");
    }
  }

  /// 알림 수신 처리 (메시지 앱 알림 포함)
  Future<void> _handleNotificationPosted(dynamic arguments) async {
    try {
      debugPrint("📩 [SmsListener] 알림 수신됨: $arguments");

      if (!await _canRun()) {
        debugPrint("🚫 [SmsListener] Guardian 모드 - 스킵");
        return;
      }

      final Map<String, dynamic> data = Map<String, dynamic>.from(arguments);
      final packageName = data['packageName'] as String? ?? '';
      final title = data['title'] as String? ?? '';
      final text = data['text'] as String? ?? '';

      debugPrint("📱 [SmsListener] 패키지: $packageName, 발신자: $title, 내용: $text");

      // SMS/메시지 관련 패키지만 처리
      final smsPackages = [
        'com.samsung.android.messaging',
        'com.google.android.apps.messaging',
        'com.android.mms',
        'com.skt.prod.dialer',
        'com.kt.tphone',
        'com.lguplus.usimsafe',
      ];

      if (smsPackages.any((pkg) => packageName.contains(pkg))) {
        debugPrint("📱 [SmsListener] SMS 앱 알림 - 업로드 시작");

        await _uploadService.uploadSmsLog(
          sender: title,
          message: text,
          timestamp: DateTime.now(),
          packageName: packageName, // ✅ [추가] 패키지명 전달
        );

        debugPrint("✅ [SmsListener] SMS 업로드 완료");
      } else {
        debugPrint("⏭️ [SmsListener] SMS 앱이 아님 - 스킵: $packageName");
      }
    } catch (e) {
      debugPrint("❌ [SmsListener] 알림 처리 오류: $e");
    }
  }

  /// 알림 접근 권한 확인
  Future<bool> checkNotificationAccessPermission() async {
    try {
      final result = await _channel.invokeMethod('checkNotificationAccess');
      return result == true;
    } catch (e) {
      debugPrint("❌ [SmsListener] 권한 확인 오류: $e");
      return false;
    }
  }

  /// 알림 접근 설정 화면 열기
  Future<void> openNotificationAccessSettings() async {
    try {
      await _channel.invokeMethod('openNotificationAccessSettings');
    } catch (e) {
      debugPrint("❌ [SmsListener] 설정 열기 오류: $e");
    }
  }

  /// 서비스 중지
  void dispose() {
    _isInitialized = false;
    debugPrint("🛑 [SmsListener] 서비스 중지");
  }
}
