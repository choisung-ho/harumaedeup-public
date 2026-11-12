// lib/services/permission_service.dart
// 앱 권한 관리 서비스
// role별 권한 확인 및 라우팅 결정

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// 권한 관리 서비스
class PermissionService {
  // 싱글톤
  static final PermissionService _instance = PermissionService._internal();
  factory PermissionService() => _instance;
  PermissionService._internal();

  /// ✅ [시니어용] 모든 필수 권한이 허용되었는지 확인
  Future<bool> areSeniorPermissionsGranted() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final sdkInt = androidInfo.version.sdkInt;

      // 1. 저장소 권한
      bool storageGranted = false;
      if (sdkInt >= 33) {
        final photos = await Permission.photos.status;
        final videos = await Permission.videos.status;
        final audio = await Permission.audio.status;
        storageGranted =
            photos.isGranted && videos.isGranted && audio.isGranted;
      } else if (sdkInt >= 30) {
        storageGranted =
            await Permission.manageExternalStorage.isGranted ||
            await Permission.storage.isGranted;
      } else {
        storageGranted = await Permission.storage.isGranted;
      }

      // 2. 카메라 권한
      final cameraGranted = await Permission.camera.isGranted;

      // 3. 마이크 권한
      final microphoneGranted = await Permission.microphone.isGranted;

      // 4. 알림 권한
      final notificationGranted = await Permission.notification.isGranted;

      // 5. 위치 권한 (✅ locationWhenInUse 사용)
      final locationGranted = await Permission.locationWhenInUse.isGranted;

      final allGranted =
          storageGranted &&
          cameraGranted &&
          microphoneGranted &&
          notificationGranted &&
          locationGranted;

      debugPrint("""
📋 [Senior Permission Check]
  - Storage: $storageGranted
  - Camera: $cameraGranted
  - Microphone: $microphoneGranted
  - Notification: $notificationGranted
  - Location: $locationGranted
  - All Granted: $allGranted
      """);

      return allGranted;
    } catch (e) {
      debugPrint("❌ [PermissionService] 권한 확인 오류: $e");
      return false;
    }
  }

  /// ✅ [보호자용] 알림 권한만 확인
  Future<bool> areGuardianPermissionsGranted() async {
    try {
      final notificationGranted = await Permission.notification.isGranted;
      debugPrint(
        "📋 [Guardian Permission Check] Notification: $notificationGranted",
      );
      return notificationGranted;
    } catch (e) {
      debugPrint("❌ [PermissionService] 권한 확인 오류: $e");
      return false;
    }
  }

  /// ✅ [role별] 해당 role에 맞는 권한이 있는지 확인
  Future<bool> arePermissionsGrantedForRole(String role) async {
    if (role == '1') {
      // 보호자: 알림 권한만
      return await areGuardianPermissionsGranted();
    } else if (role == '2') {
      // 시니어: 모든 권한
      return await areSeniorPermissionsGranted();
    }
    return false;
  }

  /// ✅ [해당 role에 맞는] 권한 설정 완료 여부 확인 (SharedPreferences)
  Future<bool> isPermissionCompletedForRole(String role) async {
    final prefs = await SharedPreferences.getInstance();
    if (role == '1') {
      return prefs.getBool('guardian_permissions_completed') ?? false;
    } else if (role == '2') {
      return prefs.getBool('senior_permissions_completed') ?? false;
    }
    return false;
  }

  /// ✅ [해당 role에 맞는] 권한 설정 완료 저장
  Future<void> setPermissionCompletedForRole(String role) async {
    final prefs = await SharedPreferences.getInstance();
    if (role == '1') {
      await prefs.setBool('guardian_permissions_completed', true);
      debugPrint("✅ [Permission] 보호자 권한 설정 완료 저장");
    } else if (role == '2') {
      await prefs.setBool('senior_permissions_completed', true);
      // 기존 호환성
      await prefs.setBool('is_onboarding_completed', true);
      await prefs.setBool('permissions_configured', true);
      debugPrint("✅ [Permission] 시니어 권한 설정 완료 저장");
    }
  }

  /// ✅ [핵심] 권한 페이지로 이동해야 하는지 결정 (role 기반)
  Future<bool> shouldShowPermissionPageForRole(String role) async {
    // 1. 이미 해당 role에 대한 권한 설정을 완료했는지 확인
    final isCompleted = await isPermissionCompletedForRole(role);
    if (isCompleted) {
      debugPrint("✅ [Permission] role=$role 권한 설정 완료됨 -> 권한 페이지 스킵");
      return false;
    }

    // 2. 실제 권한 상태 확인
    final hasPermissions = await arePermissionsGrantedForRole(role);
    if (hasPermissions) {
      // 권한이 이미 있으면 완료 상태로 저장하고 스킵
      await setPermissionCompletedForRole(role);
      debugPrint("✅ [Permission] role=$role 권한 이미 있음 -> 완료 저장 후 스킵");
      return false;
    }

    debugPrint("📱 [Permission] role=$role 권한 필요 -> 권한 페이지 표시");
    return true;
  }

  /// 현재 사용자 역할 확인
  Future<String?> getCurrentUserRole() async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null) return null;

    final prefs = await SharedPreferences.getInstance();
    final role = prefs.getString('user_role_$currentUid');
    debugPrint("🔍 [PermissionService] UID=$currentUid, role=$role");
    return role;
  }

  /// 시니어 모드인지 확인
  Future<bool> isSeniorMode() async {
    final role = await getCurrentUserRole();
    return role == '2';
  }

  /// Guardian 모드인지 확인
  Future<bool> isGuardianMode() async {
    final role = await getCurrentUserRole();
    return role == '1';
  }

  /// 권한 설정 리셋 (테스트/디버그용)
  Future<void> resetPermissions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('is_onboarding_completed');
    await prefs.remove('permissions_configured');
    await prefs.remove('guardian_permissions_completed');
    await prefs.remove('senior_permissions_completed');
    debugPrint("🔄 [Permission] 권한 설정 리셋 완료");
  }
}
