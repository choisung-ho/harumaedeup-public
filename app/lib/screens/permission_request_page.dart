// lib/screens/permission_request_page.dart
// 권한 요청 페이지 (role별 분기: 시니어=전체권한, 보호자=알림권한만)
// 큰 폰트와 버튼으로 어르신 접근성 최적화

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:android_intent_plus/android_intent.dart';

import 'package:firebase_auth/firebase_auth.dart';

import 'home_page.dart';
import 'guardian_home_page.dart';
import '../services/permission_service.dart';
import '../theme_state.dart'; // ✅ [추가] 다크모드 지원

// ✅ [추가] SMS 리스너 채널 (알림 접근 권한 확인용)
const MethodChannel _smsChannel = MethodChannel(
  'com.example.my_first_app/sms_listener',
);

// ✅ [추가] SAF 채널 정의
const MethodChannel _safChannel = MethodChannel('com.example.my_first_app/saf');

class PermissionRequestPage extends StatefulWidget {
  final String role; // '1' = 보호자, '2' = 시니어

  const PermissionRequestPage({super.key, required this.role});

  @override
  State<PermissionRequestPage> createState() => _PermissionRequestPageState();
}

class _PermissionRequestPageState extends State<PermissionRequestPage>
    with WidgetsBindingObserver {
  // 권한 상태 관리
  bool _storageGranted = false;
  bool _cameraGranted = false;
  bool _microphoneGranted = false;
  bool _notificationGranted = false;
  bool _notificationAccessGranted = false; // 알림 접근 (SMS 감지용)
  bool _safFolderSelected = false;
  bool _locationGranted = false;
  bool _batteryOptimizationDisabled = false; // ✅ [추가] 배터리 최적화 예외

  bool _isLoading = true;
  int _currentStep = 0; // 0: 소개, 1: 권한 요청, 2: 완료

  // 시니어 모드인지 확인
  bool get _isSeniorMode => widget.role == '2';
  bool get _isGuardianMode => widget.role == '1';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAllPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 앱이 다시 포그라운드로 돌아올 때 권한 재확인
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // ✅ [핵심] 일괄 모드일 때는 권한 재확인 건너뛰기 (깜빡임 방지)
      if (_isBatchMode || _isRequestingAllPermissions) {
        debugPrint("🔄 일괄 모드 중 - 권한 재확인 건너뜀");
        return;
      }

      // ✅ 문자 알림 접근 설정 화면에서 돌아온 경우 - 실제 권한 체크
      if (_isWaitingForNotificationAccess) {
        _isWaitingForNotificationAccess = false;
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _handleNotificationAccessReturn();
        });
        return;
      }

      _checkAllPermissionsSilent();
    }
  }

  /// 모든 권한 상태 확인 (초기 로딩용 - setState 포함)
  Future<void> _checkAllPermissions() async {
    setState(() => _isLoading = true);
    await _checkPermissionStates();
    if (mounted) setState(() => _isLoading = false);
  }

  /// ✅ [추가] 권한 상태만 조용히 확인 (setState 없음 - 깜빡임 방지)
  Future<void> _checkAllPermissionsSilent() async {
    await _checkPermissionStates();
    // 상태가 변경되었을 때만 UI 업데이트
    if (mounted) setState(() {});
  }

  /// ✅ [추가] 실제 권한 상태 체크 로직 (분리)
  Future<void> _checkPermissionStates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final sdkInt = androidInfo.version.sdkInt;

      // 1. 저장소 권한 (Android 버전별 분기)
      if (sdkInt >= 33) {
        // Android 13+: 개별 미디어 권한
        final photos = await Permission.photos.status;
        final videos = await Permission.videos.status;
        final audio = await Permission.audio.status;
        _storageGranted =
            photos.isGranted && videos.isGranted && audio.isGranted;
      } else if (sdkInt >= 30) {
        // Android 11-12: MANAGE_EXTERNAL_STORAGE 또는 기본 저장소
        _storageGranted =
            await Permission.manageExternalStorage.isGranted ||
            await Permission.storage.isGranted;
      } else {
        // Android 10 이하
        _storageGranted = await Permission.storage.isGranted;
      }

      // 2. 카메라 권한
      _cameraGranted = await Permission.camera.isGranted;

      // 3. 마이크 권한
      _microphoneGranted = await Permission.microphone.isGranted;

      // 4. 알림 권한
      _notificationGranted = await Permission.notification.isGranted;

      // 5. 위치 권한 (✅ locationAlways로 변경 - "항상 허용" 권한 체크)
      _locationGranted = await Permission.locationAlways.isGranted;

      // 6. SAF 폴더 선택 여부
      _safFolderSelected =
          prefs.getString('recording_folder_uri') != null ||
          prefs.getString('recording_folder_path') != null;

      // 7. 알림 접근 권한 (설정에서 직접 활성화 필요)
      _notificationAccessGranted =
          prefs.getBool('notification_access_granted') ?? false;

      // 8. 배터리 최적화 예외 권한 확인
      if (Platform.isAndroid) {
        _batteryOptimizationDisabled =
            await Permission.ignoreBatteryOptimizations.isGranted;
      }
    } catch (e) {
      debugPrint("권한 확인 오류: $e");
    }
  }

  /// 저장소 권한 요청
  Future<void> _requestStoragePermission() async {
    // ✅ 일괄 모드에서는 Silent 함수 사용
    if (_isBatchMode) {
      await _requestStoragePermissionSilent();
      return;
    }

    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;
    final sdkInt = androidInfo.version.sdkInt;

    if (sdkInt >= 33) {
      // Android 13+: 개별 미디어 권한 요청
      Map<Permission, PermissionStatus> statuses = await [
        Permission.photos,
        Permission.videos,
        Permission.audio,
      ].request();

      _storageGranted = statuses.values.every((s) => s.isGranted);
    } else if (sdkInt >= 30) {
      // Android 11+: 모든 파일 접근 권한
      final status = await Permission.manageExternalStorage.request();
      if (status.isPermanentlyDenied) {
        _showSettingsDialog("저장소");
        return;
      }
      _storageGranted = status.isGranted;
    } else {
      final status = await Permission.storage.request();
      if (status.isPermanentlyDenied) {
        _showSettingsDialog("저장소");
        return;
      }
      _storageGranted = status.isGranted;
    }

    // ✅ [핵심 추가] 저장소 권한 받은 시간 저장 - 이 시간 이후 파일만 업로드됨
    if (_storageGranted) {
      final prefs = await SharedPreferences.getInstance();
      // 이미 저장된 시간이 없는 경우에만 저장 (재권한 시 기존 시간 유지)
      if (prefs.getInt('storage_permission_time') == null) {
        await prefs.setInt(
          'storage_permission_time',
          DateTime.now().millisecondsSinceEpoch,
        );
        debugPrint("📅 저장소 권한 시간 저장: ${DateTime.now()}");
      }
    }

    // ✅ 개별 요청 시에만 UI 업데이트
    if (mounted) setState(() {});
  }

  /// 카메라 권한 요청
  Future<void> _requestCameraPermission() async {
    if (_isBatchMode) return; // ✅ 일괄 모드에서는 직접 호출 무시

    final status = await Permission.camera.request();
    if (status.isPermanentlyDenied) {
      _showSettingsDialog("카메라");
      return;
    }
    _cameraGranted = status.isGranted;
    if (mounted) setState(() {});
  }

  /// 마이크 권한 요청
  Future<void> _requestMicrophonePermission() async {
    if (_isBatchMode) return; // ✅ 일괄 모드에서는 직접 호출 무시

    final status = await Permission.microphone.request();
    if (status.isPermanentlyDenied) {
      _showSettingsDialog("마이크");
      return;
    }
    _microphoneGranted = status.isGranted;
    if (mounted) setState(() {});
  }

  /// 알림 권한 요청
  Future<void> _requestNotificationPermission() async {
    if (_isBatchMode) return; // ✅ 일괄 모드에서는 직접 호출 무시

    final status = await Permission.notification.request();
    if (status.isPermanentlyDenied) {
      _showSettingsDialog("알림");
      return;
    }
    _notificationGranted = status.isGranted;
    if (mounted) setState(() {});
  }

  /// 위치 권한 요청 (항상 허용) - 안내 다이얼로그 포함
  Future<void> _requestLocationPermission() async {
    if (_isBatchMode) return; // ✅ 일괄 모드에서는 직접 호출 무시

    // ✅ 이미 "항상 허용" 권한이 있는지 먼저 확인
    final alreadyGranted = await Permission.locationAlways.isGranted;
    if (alreadyGranted) {
      _locationGranted = true;
      if (mounted) setState(() {});
      return;
    }

    // ✅ [1단계] 먼저 안내 다이얼로그 표시
    final shouldProceed = await _showLocationPermissionGuideDialog();
    if (!shouldProceed) return;

    // ✅ [2단계] locationWhenInUse 권한 요청
    final whenInUseStatus = await Permission.locationWhenInUse.request();
    if (whenInUseStatus.isPermanentlyDenied) {
      _showSettingsDialog("위치");
      return;
    }

    if (!whenInUseStatus.isGranted) {
      _locationGranted = false;
      if (mounted) setState(() {});
      return;
    }

    // ✅ [3단계] "항상 허용" 안내 후 설정 페이지로 이동
    await _showLocationAlwaysGuideDialog();

    // ✅ [4단계] 유효성 검사 - 실제로 "항상 허용"이 되었는지 확인
    final alwaysStatus = await Permission.locationAlways.isGranted;
    _locationGranted = alwaysStatus;

    if (mounted) {
      setState(() {});
      if (_locationGranted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ 위치 권한이 "항상 허용"으로 설정되었습니다!'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚠️ "항상 허용"을 선택해주세요'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  /// ✅ [추가] 위치 권한 안내 다이얼로그 (1단계 - 왜 필요한지 설명)
  Future<bool> _showLocationPermissionGuideDialog() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor = const Color(0xFF2E7D32);

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: accentColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.location_on_rounded,
                color: accentColor,
                size: 28,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                '위치 권한 안내',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF2D5A40).withOpacity(0.3)
                      : const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accentColor.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '📍 이 앱은 "항상 허용" 권한이 필요합니다',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildGuideItem(
                      Icons.elderly_rounded,
                      '어르신의 위치를 보호자가 확인할 수 있어요',
                      isDark,
                    ),
                    _buildGuideItem(
                      Icons.history_rounded,
                      '이동 기록을 자동으로 저장해요',
                      isDark,
                    ),
                    _buildGuideItem(
                      Icons.security_rounded,
                      '앱을 사용하지 않을 때도 안전하게 보호해요',
                      isDark,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '다음 화면에서 "앱 사용 중에만 허용"을\n먼저 선택해주세요',
                style: TextStyle(
                  fontSize: 15,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              '취소',
              style: TextStyle(
                fontSize: 16,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: accentColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            child: const Text(
              '확인',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  /// ✅ [추가] "항상 허용" 설정 안내 다이얼로그 (2단계 - 설정 페이지 이동 전)
  Future<void> _showLocationAlwaysGuideDialog() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor = const Color(0xFF2E7D32);

    // 설정 페이지 이동 플래그
    bool _isWaitingForLocationSettings = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.settings_rounded,
                color: Colors.blue,
                size: 28,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                '"항상 허용" 설정 방법',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 단계별 안내
              _buildStepItem('1', '아래 버튼을 눌러 설정으로 이동', isDark, accentColor),
              _buildStepItem('2', '"위치" 또는 "권한" 메뉴 선택', isDark, accentColor),
              _buildStepItem(
                '3',
                '"항상 허용" 선택',
                isDark,
                accentColor,
                isLast: true,
              ),
              const SizedBox(height: 16),
              // 시각적 안내 박스
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(isDark ? 0.2 : 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.touch_app_rounded,
                      color: Colors.blue,
                      size: 32,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '"항상 허용"을 꼭 선택해주세요!',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '선택 후 뒤로 버튼을 눌러 돌아오세요',
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              '나중에',
              style: TextStyle(
                fontSize: 16,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(context);
              // 위치 권한 설정 페이지로 이동
              await openAppSettings();
            },
            icon: const Icon(Icons.open_in_new_rounded, size: 20),
            label: const Text(
              '설정으로 이동',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// ✅ [추가] 안내 항목 위젯
  Widget _buildGuideItem(IconData icon, String text, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: isDark ? Colors.white70 : Colors.black54),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// ✅ [추가] 단계 안내 위젯
  Widget _buildStepItem(
    String step,
    String text,
    bool isDark,
    Color accentColor, {
    bool isLast = false,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: accentColor,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                step,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 15,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// ✅ [추가] 통화 녹음 폴더 경로 안내 바텀시트
  Future<void> _showCallRecordingFolderGuide() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor = const Color(0xFF2E7D32);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkSurface : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 핸들 바
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // 헤더
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: accentColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                Icons.folder_open_rounded,
                color: accentColor,
                size: 28,
              ),
            ),
            const SizedBox(height: 16),

            Text(
              '통화 녹음 폴더 위치 안내',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: isDark
                    ? AppColors.darkOnSurface
                    : const Color(0xFF1B1B1B),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '갤럭시 기기의 통화 녹음 파일은\n아래 경로에 저장됩니다',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: isDark
                    ? AppColors.darkOnSurfaceVariant
                    : const Color(0xFF6B7280),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),

            // 경로 안내 카드
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withOpacity(0.05)
                    : const Color(0xFFF8FAF8),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark ? Colors.white10 : const Color(0xFFE5E7EB),
                ),
              ),
              child: Column(
                children: [
                  // 경로 표시
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: accentColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.smartphone_rounded,
                          color: accentColor,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '기본 저장 경로',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? AppColors.darkOnSurfaceVariant
                                    : const Color(0xFF6B7280),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '내장 메모리 > Recordings > Call',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? AppColors.darkOnSurface
                                    : const Color(0xFF1B1B1B),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // 단계별 안내
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withOpacity(0.03)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        _buildPathStep(
                          step: '1',
                          text: '내 파일 앱 또는 내장 메모리 선택',
                          isDark: isDark,
                          accentColor: accentColor,
                        ),
                        _buildPathStep(
                          step: '2',
                          text: 'Recordings 폴더 선택',
                          isDark: isDark,
                          accentColor: accentColor,
                        ),
                        _buildPathStep(
                          step: '3',
                          text: 'Call 폴더 선택 후 완료',
                          isDark: isDark,
                          accentColor: accentColor,
                          isLast: true,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // 참고 안내
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(isDark ? 0.15 : 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.lightbulb_outline_rounded,
                    color: Colors.amber.shade700,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '폴더 선택 창에서 상단의 메뉴(☰)를 눌러\n내장 메모리로 이동할 수 있어요',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark
                            ? Colors.amber.shade300
                            : Colors.amber.shade800,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // 버튼
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  _selectCallRecordingFolder();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  '폴더 선택하기',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 경로 안내 단계 위젯
  Widget _buildPathStep({
    required String step,
    required String text,
    required bool isDark,
    required Color accentColor,
    bool isLast = false,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: accentColor,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                step,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                color: isDark
                    ? AppColors.darkOnSurface
                    : const Color(0xFF374151),
              ),
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: isDark ? Colors.white24 : Colors.grey.shade400,
            size: 18,
          ),
        ],
      ),
    );
  }

  /// SAF로 통화 녹음 폴더 선택 (Android Native Intent 사용)
  Future<void> _selectCallRecordingFolder() async {
    try {
      // ✅ [수정] Android Native SAF Intent로 폴더 선택 (content:// URI 획득)
      final String? selectedUri = await _safChannel.invokeMethod('pickFolder');

      if (selectedUri != null && selectedUri.startsWith('content://')) {
        final prefs = await SharedPreferences.getInstance();

        // SAF URI 저장 (content:// 형식)
        await prefs.setString('recording_folder_uri', selectedUri);
        // 일반 경로는 null로 설정 (SAF 모드 사용)
        await prefs.remove('recording_folder_path');

        // ✅ [핵심 추가] SAF 폴더 권한 받은 시간 저장 - 이 시간 이후 파일만 업로드됨
        await prefs.setInt(
          'saf_folder_permission_time',
          DateTime.now().millisecondsSinceEpoch,
        );
        debugPrint("📅 SAF 폴더 권한 시간 저장: ${DateTime.now()}");

        // ✅ [핵심 추가] 디스크에 즉시 동기화 확인
        await prefs.reload();

        // ✅ [검증] 저장된 값 즉시 확인
        final savedUri = prefs.getString('recording_folder_uri');
        debugPrint("✅ SAF 폴더 URI 저장 완료: $selectedUri");
        debugPrint("✅ SAF 폴더 URI 검증: $savedUri");

        if (savedUri == null) {
          debugPrint("❌ SAF URI 저장 실패! 재시도...");
          // 재시도
          await prefs.setString('recording_folder_uri', selectedUri);
          await prefs.reload();
          debugPrint(
            "🔄 재시도 후 URI: ${prefs.getString('recording_folder_uri')}",
          );
        }

        _safFolderSelected = true;
        if (!_isBatchMode) setState(() {});

        if (mounted && !_isBatchMode) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ 통화 녹음 폴더가 설정되었습니다!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        debugPrint("⚠️ SAF 폴더 선택 취소 또는 실패");
      }
    } catch (e) {
      debugPrint("폴더 선택 오류: $e");

      // SAF 실패 시 FilePicker 폴백 시도
      try {
        String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '📁 통화 녹음 폴더를 선택해주세요\n(보통 Recordings/Call)',
        );

        if (selectedDirectory != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('recording_folder_path', selectedDirectory);
          // URI는 제거 (일반 경로 모드 사용)
          await prefs.remove('recording_folder_uri');

          // ✅ [핵심 추가] 폴더 권한 받은 시간 저장 - 이 시간 이후 파일만 업로드됨
          await prefs.setInt(
            'saf_folder_permission_time',
            DateTime.now().millisecondsSinceEpoch,
          );
          debugPrint("📅 폴더 권한 시간 저장 (FilePicker): ${DateTime.now()}");

          // ✅ [핵심 추가] 디스크에 즉시 동기화
          await prefs.reload();
          debugPrint("✅ 일반 경로 저장 완료: $selectedDirectory");

          _safFolderSelected = true;
          if (!_isBatchMode) setState(() {});

          if (mounted && !_isBatchMode) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('✅ 통화 녹음 폴더가 설정되었습니다! (일반 모드)'),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
      } catch (e2) {
        debugPrint("FilePicker 폴백도 실패: $e2");
        if (mounted && !_isBatchMode) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('폴더 선택 중 오류: $e')));
        }
      }
    }
  }

  /// ✅ [핵심 추가] 배터리 최적화 안내 다이얼로그
  Future<void> _showBatteryOptimizationDialog() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.battery_alert, color: Colors.orange.shade700, size: 32),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                '백그라운드 실행 허용',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '이 앱은 다음 기능을 위해 백그라운드에서\n계속 실행되어야 합니다:',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              _buildReasonItem(Icons.location_on, '실시간 위치 추적'),
              _buildReasonItem(Icons.photo, '사진/동영상 자동 업로드'),
              _buildReasonItem(Icons.call, '통화 녹음 자동 업로드'),
              _buildReasonItem(Icons.message, 'SMS 알림 기록'),
              _buildReasonItem(Icons.notifications_active, '약 복용 알림 수신'),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.amber.shade300),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Colors.amber.shade800,
                      size: 24,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '이 설정을 하지 않으면\n앱이 자동으로 꺼질 수 있어요',
                        style: TextStyle(
                          fontSize: 15,
                          color: Colors.amber.shade900,
                          fontWeight: FontWeight.w500,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              '나중에',
              style: TextStyle(color: Colors.grey, fontSize: 18),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4CAF50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            child: const Text(
              '설정하기',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (result == true) {
      await _requestBatteryOptimization();
    }
  }

  /// ✅ [추가] 배터리 최적화 안내 항목 위젯
  Widget _buildReasonItem(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: const Color(0xFF4CAF50), size: 22),
          ),
          const SizedBox(width: 14),
          Text(text, style: const TextStyle(fontSize: 16)),
        ],
      ),
    );
  }

  /// ✅ [추가] 배터리 최적화 예외 권한 요청
  Future<void> _requestBatteryOptimization() async {
    final status = await Permission.ignoreBatteryOptimizations.request();
    _batteryOptimizationDisabled = status.isGranted;

    if (!_isBatchMode) {
      setState(() {});
    }

    if (status.isGranted) {
      debugPrint('🔋 배터리 최적화 예외 설정 완료');
      if (mounted && !_isBatchMode) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ 백그라운드 실행이 허용되었습니다!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } else if (status.isPermanentlyDenied && !_isBatchMode) {
      // 영구 거부 시 설정으로 안내
      _showSettingsDialog("배터리 최적화");
    }
  }

  /// 알림 접근 권한 설정 화면으로 이동 (SMS 감지용)
  bool _isWaitingForNotificationAccess = false; // ✅ [추가] 설정 화면 이동 플래그

  Future<void> _openNotificationAccessSettings() async {
    try {
      if (Platform.isAndroid) {
        // ✅ 설정 화면 이동 전 플래그 설정
        _isWaitingForNotificationAccess = true;

        const intent = AndroidIntent(
          action: 'android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS',
        );
        await intent.launch();
      }
    } catch (e) {
      debugPrint("알림 접근 설정 열기 오류: $e");
      _isWaitingForNotificationAccess = false;
      openAppSettings();
    }
  }

  /// ✅ [추가] 실제 알림 접근 권한 체크 (네이티브 호출)
  Future<bool> _checkNotificationAccessGranted() async {
    try {
      final bool isGranted = await _smsChannel.invokeMethod(
        'checkNotificationAccess',
      );
      return isGranted;
    } catch (e) {
      debugPrint("알림 접근 권한 확인 오류: $e");
      return false;
    }
  }

  /// ✅ [추가] 설정 화면에서 돌아온 후 권한 체크 및 UI 업데이트
  Future<void> _handleNotificationAccessReturn() async {
    final isGranted = await _checkNotificationAccessGranted();

    if (isGranted) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('notification_access_granted', true);
      _notificationAccessGranted = true;

      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ 문자 알림 접근이 설정되었습니다!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚠️ 문자 알림 접근 권한이 허용되지 않았습니다'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  /// 권한 영구 거부 시 설정으로 안내
  void _showSettingsDialog(String permissionName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          '$permissionName 권한 필요',
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        content: Text(
          '앱 설정에서 $permissionName 권한을\n직접 허용해주세요.',
          style: const TextStyle(fontSize: 20),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소', style: TextStyle(fontSize: 18)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: const Text('설정으로 이동', style: TextStyle(fontSize: 18)),
          ),
        ],
      ),
    );
  }

  /// 모든 필수 권한이 허용되었는지 확인 (role별 분기)
  bool get _allRequiredPermissionsGranted {
    if (_isGuardianMode) {
      // 보호자: 알림 권한만 필요
      return _notificationGranted;
    }
    // 시니어: 모든 권한 + 배터리 최적화 필요
    return _storageGranted &&
        _cameraGranted &&
        _microphoneGranted &&
        _notificationGranted &&
        _locationGranted &&
        _batteryOptimizationDisabled; // ✅ [추가]
  }

  /// 모든 권한(선택 포함)이 설정되었는지 확인
  bool get _allPermissionsConfigured {
    if (_isGuardianMode) {
      // 보호자: 알림 권한만
      return _notificationGranted;
    }
    // 시니어: 전체 권한 + 선택 항목 + 배터리 최적화
    return _allRequiredPermissionsGranted &&
        _safFolderSelected &&
        _notificationAccessGranted &&
        _batteryOptimizationDisabled; // ✅ [추가]
  }

  /// ✅ [추가] 모든 필수 권한을 한 번에 요청
  bool _isRequestingAllPermissions = false;
  bool _isBatchMode = false; // ✅ [추가] 일괄 요청 모드 (setState 호출 방지)

  Future<void> _requestAllPermissions() async {
    if (_isRequestingAllPermissions) return;

    // ✅ 일괄 모드 먼저 설정 (setState 전에)
    _isBatchMode = true;
    _isRequestingAllPermissions = true;

    // ✅ 한 번만 UI 업데이트 (로딩 표시)
    if (mounted) setState(() {});

    try {
      // ========== 시스템 권한만 순차적으로 요청 (UI 업데이트 없음) ==========

      // 1. 저장소 권한
      if (!_storageGranted) {
        await _requestStoragePermissionSilent();
      }

      // 2. 카메라 권한
      if (!_cameraGranted) {
        final status = await Permission.camera.request();
        _cameraGranted = status.isGranted;
      }

      // 3. 마이크 권한
      if (!_microphoneGranted) {
        final status = await Permission.microphone.request();
        _microphoneGranted = status.isGranted;
      }

      // 4. 알림 권한
      if (!_notificationGranted) {
        final status = await Permission.notification.request();
        _notificationGranted = status.isGranted;
      }

      // 5. 위치 권한 (2단계: whenInUse -> always "항상 허용")
      if (!_locationGranted) {
        // ✅ 먼저 현재 상태 확인
        final alreadyGranted = await Permission.locationAlways.isGranted;
        if (alreadyGranted) {
          _locationGranted = true;
        } else {
          // 1단계: locationWhenInUse 권한 요청
          final whenInUseStatus = await Permission.locationWhenInUse.request();
          if (whenInUseStatus.isGranted) {
            // 2단계: locationAlways 권한 요청
            final alwaysStatus = await Permission.locationAlways.request();
            // ✅ 유효성 검사 - 실제로 granted 되었는지 재확인
            _locationGranted = await Permission.locationAlways.isGranted;
          } else {
            _locationGranted = false;
          }
        }
      }

      // 6. 배터리 최적화 예외
      if (!_batteryOptimizationDisabled) {
        final status = await Permission.ignoreBatteryOptimizations.request();
        _batteryOptimizationDisabled = status.isGranted;
      }

      // ========== 참고: SAF 폴더 선택 & 문자 알림 접근은 별도 ==========
      // - SAF 폴더 선택: 사용자가 직접 "통화 녹음 폴더" 카드를 눌러서 선택
      // - 문자 알림 접근: 설정 화면 이동 필요하므로 별도 안내
      // 이 두 가지는 일괄 요청에서 제외 (사용자 인터랙션 필요)
    } catch (e) {
      debugPrint('권한 일괄 요청 오류: $e');
    } finally {
      // ✅ 일괄 모드 종료
      _isBatchMode = false;
      _isRequestingAllPermissions = false;

      if (mounted) {
        // ✅ 모든 권한 요청 완료 후 한 번만 UI 업데이트
        setState(() {});

        // ✅ 정확한 상태 메시지 표시
        if (_allRequiredPermissionsGranted) {
          // 필수 권한 완료
          String message = '✅ 필수 권한이 모두 허용되었습니다!';
          if (!_safFolderSelected) {
            message += '\n📁 통화 녹음 폴더도 선택해주세요';
          }
          if (!_notificationAccessGranted) {
            message += '\n📱 문자 알림 접근도 설정해주세요';
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 3),
            ),
          );
        } else {
          // 일부 권한 거부됨
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ 일부 권한이 거부되었습니다. 개별적으로 허용해주세요.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    }
  }

  /// ✅ [추가] 저장소 권한 요청 (Silent - setState 호출 안 함)
  Future<void> _requestStoragePermissionSilent() async {
    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;
    final sdkInt = androidInfo.version.sdkInt;

    if (sdkInt >= 33) {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.photos,
        Permission.videos,
        Permission.audio,
      ].request();
      _storageGranted = statuses.values.every((s) => s.isGranted);
    } else if (sdkInt >= 30) {
      final status = await Permission.manageExternalStorage.request();
      _storageGranted = status.isGranted;
    } else {
      final status = await Permission.storage.request();
      _storageGranted = status.isGranted;
    }

    // 저장소 권한 받은 시간 저장
    if (_storageGranted) {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt('storage_permission_time') == null) {
        await prefs.setInt(
          'storage_permission_time',
          DateTime.now().millisecondsSinceEpoch,
        );
      }
    }
  }

  /// ✅ [추가] SAF 폴더 선택 (Silent - setState 호출 안 함)
  Future<void> _selectCallRecordingFolderSilent() async {
    try {
      final String? selectedUri = await _safChannel.invokeMethod('pickFolder');

      if (selectedUri != null && selectedUri.startsWith('content://')) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('recording_folder_uri', selectedUri);
        await prefs.remove('recording_folder_path');
        await prefs.setInt(
          'saf_folder_permission_time',
          DateTime.now().millisecondsSinceEpoch,
        );
        await prefs.reload();
        _safFolderSelected = true;
      }
    } catch (e) {
      debugPrint("SAF 폴더 선택 오류 (Silent): $e");
      // FilePicker 폴백
      try {
        String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '📁 통화 녹음 폴더를 선택해주세요',
        );
        if (selectedDirectory != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('recording_folder_path', selectedDirectory);
          await prefs.remove('recording_folder_uri');
          await prefs.setInt(
            'saf_folder_permission_time',
            DateTime.now().millisecondsSinceEpoch,
          );
          await prefs.reload();
          _safFolderSelected = true;
        }
      } catch (e2) {
        debugPrint("FilePicker 폴백 실패 (Silent): $e2");
      }
    }
  }

  /// 온보딩 완료 처리
  Future<void> _completeOnboarding() async {
    // ✅ [변경] role별 권한 완료 저장
    await PermissionService().setPermissionCompletedForRole(widget.role);

    if (mounted) {
      // role에 따라 홈 화면으로 이동
      if (_isGuardianMode) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (context) => const GuardianHomePage()),
          (route) => false,
        );
      } else {
        // ✅ [수정] 시니어 모드: 바로 홈으로 이동 (본인확인은 회원가입 시 완료됨)
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (context) => const DiaryHomePage()),
          (route) => false,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // ✅ [추가] 다크모드 지원
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? AppColors.darkBackground : Colors.white;
    final textColor = isDark ? AppColors.darkOnSurface : Colors.black87;

    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: _isLoading
            ? Center(
                child: CircularProgressIndicator(
                  color: isDark
                      ? AppColors.darkPrimary
                      : const Color(0xFF4CAF50),
                ),
              )
            : _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    switch (_currentStep) {
      case 0:
        return _buildIntroStep();
      case 1:
        return _buildPermissionStep();
      case 2:
        return _buildCompleteStep();
      default:
        return _buildIntroStep();
    }
  }

  /// [화면 1] 소개 페이지 (role별 분기) - 전문적인 UI
  Widget _buildIntroStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? AppColors.darkBackground : Colors.white;
    final textColor = isDark
        ? AppColors.darkOnSurface
        : const Color(0xFF1B1B1B);
    final subTextColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : const Color(0xFF6B7280);
    final accentColor = const Color(0xFF2E7D32);

    // 보호자/시니어 모드에 따른 텍스트 분기
    final String title = _isGuardianMode ? '알림 권한이\n필요합니다' : '앱 권한 설정이\n필요합니다';

    final String description = _isGuardianMode
        ? '어르신의 약 알림, 일기 알림 등\n중요한 소식을 받으실 수 있습니다'
        : '사진, 통화 녹음, 위치 정보를\n안전하게 보관하기 위해 필요합니다';

    final IconData headerIcon = _isGuardianMode
        ? Icons.notifications_active_rounded
        : Icons.verified_user_rounded;

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 아이콘
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [accentColor, const Color(0xFF43A047)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(
                        color: accentColor.withOpacity(0.35),
                        blurRadius: 24,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Icon(headerIcon, size: 48, color: Colors.white),
                ),
                const SizedBox(height: 40),
                // 제목
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    color: textColor,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 20),
                // 설명
                Text(
                  description,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 17,
                    color: subTextColor,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 48),
                // 보안 안내
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: isDark
                        ? AppColors.darkSurface
                        : const Color(0xFFF0FDF4),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: accentColor.withOpacity(0.2)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: accentColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.lock_rounded,
                          color: accentColor,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '안전한 데이터 관리',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: textColor,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '모든 정보는 암호화되어 안전하게 보관됩니다',
                              style: TextStyle(
                                fontSize: 13,
                                color: subTextColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // 하단 버튼
        Container(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          decoration: BoxDecoration(color: backgroundColor),
          child: SafeArea(
            top: false,
            child: _buildPrimaryButton(
              text: '다음',
              onPressed: () => setState(() => _currentStep = 1),
            ),
          ),
        ),
      ],
    );
  }

  /// [화면 2] 권한 요청 페이지 (role별 분기)
  Widget _buildPermissionStep() {
    // 보호자 모드: 간단하게 알림 권한만 표시
    if (_isGuardianMode) {
      return _buildGuardianPermissionStep();
    }
    // 시니어 모드: 전체 권한 표시
    return _buildSeniorPermissionStep();
  }

  /// [보호자용] 알림 권한만 요청 - 전문적인 UI
  Widget _buildGuardianPermissionStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? AppColors.darkBackground : Colors.white;
    final cardBg = isDark ? AppColors.darkSurface : const Color(0xFFF8FAF8);
    final textColor = isDark
        ? AppColors.darkOnSurface
        : const Color(0xFF1B1B1B);
    final subTextColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : const Color(0xFF6B7280);
    final accentColor = const Color(0xFF2E7D32);
    final lightAccent = isDark
        ? const Color(0xFF1B5E20).withOpacity(0.3)
        : const Color(0xFFE8F5E9);

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 40),

                // 헤더 섹션
                Center(
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [accentColor, const Color(0xFF43A047)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: accentColor.withOpacity(0.3),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.notifications_active_rounded,
                      color: Colors.white,
                      size: 40,
                    ),
                  ),
                ),
                const SizedBox(height: 28),

                Center(
                  child: Text(
                    '알림 권한 설정',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    '중요한 소식을 놓치지 않도록\n알림 권한을 허용해주세요',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      color: subTextColor,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 40),

                // 권한 설명 카드
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isDark ? Colors.white10 : const Color(0xFFE5E7EB),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: lightAccent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              Icons.info_outline_rounded,
                              color: accentColor,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '알림으로 받을 수 있는 정보',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: textColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _buildPermissionListItem(
                        icon: Icons.medication_rounded,
                        title: '약 복용 알림',
                        subtitle: '어르신의 약 복용 시간을 알려드려요',
                        isGranted: _notificationGranted,
                        isDark: isDark,
                      ),
                      _buildPermissionListItem(
                        icon: Icons.auto_stories_rounded,
                        title: '일기 알림',
                        subtitle: '새로운 일기가 작성되면 알려드려요',
                        isGranted: _notificationGranted,
                        isDark: isDark,
                      ),
                      _buildPermissionListItem(
                        icon: Icons.favorite_rounded,
                        title: '안부 소식',
                        subtitle: '어르신의 건강 상태를 알려드려요',
                        isGranted: _notificationGranted,
                        isDark: isDark,
                        isLast: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 100),
              ],
            ),
          ),
        ),

        // 하단 고정 버튼
        Container(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          decoration: BoxDecoration(
            color: backgroundColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: _notificationGranted
                ? _buildPrimaryButton(
                    text: '다음으로',
                    onPressed: () => setState(() => _currentStep = 2),
                  )
                : _buildPrimaryButton(
                    text: '알림 권한 허용하기',
                    onPressed: _requestNotificationPermission,
                  ),
          ),
        ),
      ],
    );
  }

  /// [시니어용] 전체 권한 요청 - 전문적인 UI
  Widget _buildSeniorPermissionStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? AppColors.darkBackground : Colors.white;
    final cardBg = isDark ? AppColors.darkSurface : const Color(0xFFF8FAF8);
    final textColor = isDark
        ? AppColors.darkOnSurface
        : const Color(0xFF1B1B1B);
    final subTextColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : const Color(0xFF6B7280);
    final accentColor = const Color(0xFF2E7D32);
    final lightAccent = isDark
        ? const Color(0xFF1B5E20).withOpacity(0.3)
        : const Color(0xFFE8F5E9);

    // 필수 권한 모두 허용되었는지 체크
    final allRequiredGranted =
        _storageGranted &&
        _cameraGranted &&
        _microphoneGranted &&
        _notificationGranted &&
        _locationGranted &&
        _batteryOptimizationDisabled;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 32),

                // 헤더 섹션
                Center(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [accentColor, const Color(0xFF43A047)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: accentColor.withOpacity(0.3),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.verified_user_rounded,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                Center(
                  child: Text(
                    '앱 권한 설정',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    '소중한 추억을 안전하게 보관하기 위해\n아래 권한들이 필요합니다',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: subTextColor,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 28),

                // 진행 상태 표시
                _buildProgressIndicator(isDark, accentColor),
                const SizedBox(height: 28),

                // 필수 권한 섹션
                _buildSectionHeader(
                  title: '필수 권한',
                  subtitle: '앱의 핵심 기능을 위해 반드시 필요해요',
                  icon: Icons.shield_rounded,
                  isDark: isDark,
                  accentColor: accentColor,
                ),
                const SizedBox(height: 16),

                Container(
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isDark ? Colors.white10 : const Color(0xFFE5E7EB),
                    ),
                  ),
                  child: Column(
                    children: [
                      _buildPermissionRow(
                        icon: Icons.photo_library_rounded,
                        title: '사진 및 저장소',
                        subtitle: '사진과 파일을 안전하게 백업',
                        isGranted: _storageGranted,
                        isDark: isDark,
                        accentColor: accentColor,
                      ),
                      _buildDivider(isDark),
                      _buildPermissionRow(
                        icon: Icons.camera_alt_rounded,
                        title: '카메라',
                        subtitle: '사진과 동영상 촬영',
                        isGranted: _cameraGranted,
                        isDark: isDark,
                        accentColor: accentColor,
                      ),
                      _buildDivider(isDark),
                      _buildPermissionRow(
                        icon: Icons.mic_rounded,
                        title: '마이크',
                        subtitle: '음성 녹음 및 통화',
                        isGranted: _microphoneGranted,
                        isDark: isDark,
                        accentColor: accentColor,
                      ),
                      _buildDivider(isDark),
                      _buildPermissionRow(
                        icon: Icons.notifications_rounded,
                        title: '알림',
                        subtitle: '중요한 소식 전달',
                        isGranted: _notificationGranted,
                        isDark: isDark,
                        accentColor: accentColor,
                      ),
                      _buildDivider(isDark),
                      _buildPermissionRow(
                        icon: Icons.location_on_rounded,
                        title: '위치',
                        subtitle: '현재 위치 확인',
                        isGranted: _locationGranted,
                        isDark: isDark,
                        accentColor: accentColor,
                      ),
                      _buildDivider(isDark),
                      _buildPermissionRow(
                        icon: Icons.battery_saver_rounded,
                        title: '백그라운드 실행',
                        subtitle: '자동 업로드 유지',
                        isGranted: _batteryOptimizationDisabled,
                        isDark: isDark,
                        accentColor: accentColor,
                        isLast: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // 선택 권한 섹션
                _buildSectionHeader(
                  title: '추가 설정',
                  subtitle: '더 나은 서비스를 위해 권장해요',
                  icon: Icons.tune_rounded,
                  isDark: isDark,
                  accentColor: accentColor,
                  isOptional: true,
                ),
                const SizedBox(height: 16),

                Container(
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isDark ? Colors.white10 : const Color(0xFFE5E7EB),
                    ),
                  ),
                  child: Column(
                    children: [
                      _buildOptionalPermissionRow(
                        icon: Icons.folder_open_rounded,
                        title: '통화 녹음 폴더',
                        subtitle: '통화 기록 백업 폴더 선택',
                        isGranted: _safFolderSelected,
                        isDark: isDark,
                        accentColor: accentColor,
                        onTap: _showCallRecordingFolderGuide, // ✅ 안내 페이지 먼저 표시
                      ),
                      _buildDivider(isDark),
                      _buildOptionalPermissionRow(
                        icon: Icons.sms_rounded,
                        title: '문자 알림 접근',
                        subtitle: '문자 메시지 기록',
                        isGranted: _notificationAccessGranted,
                        isDark: isDark,
                        accentColor: accentColor,
                        onTap: _openNotificationAccessSettings,
                        isLast: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 120),
              ],
            ),
          ),
        ),

        // 하단 고정 버튼
        Container(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          decoration: BoxDecoration(
            color: backgroundColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: allRequiredGranted
                ? _buildPrimaryButton(
                    text: _allPermissionsConfigured ? '설정 완료' : '기본 설정으로 진행',
                    onPressed: () => setState(() => _currentStep = 2),
                    isSecondary: !_allPermissionsConfigured,
                  )
                : _buildPrimaryButton(
                    text: _isRequestingAllPermissions
                        ? '권한 요청 중...'
                        : '모든 권한 허용하기',
                    onPressed: _isRequestingAllPermissions
                        ? null
                        : _requestAllPermissions,
                    isLoading: _isRequestingAllPermissions,
                  ),
          ),
        ),
      ],
    );
  }

  /// 진행 상태 표시 위젯
  Widget _buildProgressIndicator(bool isDark, Color accentColor) {
    final grantedCount = [
      _storageGranted,
      _cameraGranted,
      _microphoneGranted,
      _notificationGranted,
      _locationGranted,
      _batteryOptimizationDisabled,
    ].where((g) => g).length;

    final progress = grantedCount / 6;
    final textColor = isDark
        ? AppColors.darkOnSurface
        : const Color(0xFF1B1B1B);
    final subTextColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : const Color(0xFF6B7280);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accentColor.withOpacity(0.2)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '권한 설정 진행률',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              Text(
                '$grantedCount / 6 완료',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: accentColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: isDark
                  ? Colors.white12
                  : const Color(0xFFD1FAE5),
              valueColor: AlwaysStoppedAnimation<Color>(accentColor),
            ),
          ),
        ],
      ),
    );
  }

  /// 섹션 헤더 위젯
  Widget _buildSectionHeader({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isDark,
    required Color accentColor,
    bool isOptional = false,
  }) {
    final textColor = isDark
        ? AppColors.darkOnSurface
        : const Color(0xFF1B1B1B);
    final subTextColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : const Color(0xFF6B7280);

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isOptional
                ? (isDark ? Colors.white12 : const Color(0xFFF3F4F6))
                : (isDark
                      ? accentColor.withOpacity(0.2)
                      : const Color(0xFFE8F5E9)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            color: isOptional ? subTextColor : accentColor,
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
                  ),
                  if (isOptional) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white12
                            : const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '선택',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: subTextColor,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(fontSize: 13, color: subTextColor),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 권한 행 위젯 (필수)
  Widget _buildPermissionRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isGranted,
    required bool isDark,
    required Color accentColor,
    bool isLast = false,
  }) {
    final textColor = isDark
        ? AppColors.darkOnSurface
        : const Color(0xFF1B1B1B);
    final subTextColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : const Color(0xFF6B7280);

    return Padding(
      padding: EdgeInsets.fromLTRB(20, isLast ? 16 : 16, 20, isLast ? 16 : 16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: isGranted
                  ? accentColor.withOpacity(0.1)
                  : (isDark ? Colors.white10 : const Color(0xFFF3F4F6)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              color: isGranted ? accentColor : subTextColor,
              size: 22,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 13, color: subTextColor),
                ),
              ],
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: isGranted ? accentColor : Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(
                color: isGranted
                    ? accentColor
                    : (isDark ? Colors.white24 : const Color(0xFFD1D5DB)),
                width: 2,
              ),
            ),
            child: isGranted
                ? const Icon(Icons.check_rounded, color: Colors.white, size: 18)
                : null,
          ),
        ],
      ),
    );
  }

  /// 선택 권한 행 위젯 (탭 가능)
  Widget _buildOptionalPermissionRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isGranted,
    required bool isDark,
    required Color accentColor,
    required VoidCallback onTap,
    bool isLast = false,
  }) {
    final textColor = isDark
        ? AppColors.darkOnSurface
        : const Color(0xFF1B1B1B);
    final subTextColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : const Color(0xFF6B7280);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isGranted ? null : onTap,
        borderRadius: isLast
            ? const BorderRadius.only(
                bottomLeft: Radius.circular(20),
                bottomRight: Radius.circular(20),
              )
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isGranted
                      ? accentColor.withOpacity(0.1)
                      : (isDark ? Colors.white10 : const Color(0xFFF3F4F6)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: isGranted ? accentColor : subTextColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 13, color: subTextColor),
                    ),
                  ],
                ),
              ),
              if (isGranted)
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: accentColor,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                )
              else
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: subTextColor,
                  size: 16,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 구분선 위젯
  Widget _buildDivider(bool isDark) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: 80,
      color: isDark ? Colors.white10 : const Color(0xFFF3F4F6),
    );
  }

  /// 권한 리스트 아이템 위젯 (보호자용)
  Widget _buildPermissionListItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isGranted,
    required bool isDark,
    bool isLast = false,
  }) {
    final accentColor = const Color(0xFF2E7D32);
    final textColor = isDark
        ? AppColors.darkOnSurface
        : const Color(0xFF1B1B1B);
    final subTextColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : const Color(0xFF6B7280);

    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: isGranted
                  ? accentColor.withOpacity(0.1)
                  : (isDark ? Colors.white10 : const Color(0xFFF3F4F6)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              color: isGranted ? accentColor : subTextColor,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 13, color: subTextColor),
                ),
              ],
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: isGranted ? accentColor : Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(
                color: isGranted
                    ? accentColor
                    : (isDark ? Colors.white24 : const Color(0xFFD1D5DB)),
                width: 2,
              ),
            ),
            child: isGranted
                ? const Icon(Icons.check_rounded, color: Colors.white, size: 16)
                : null,
          ),
        ],
      ),
    );
  }

  /// 메인 버튼 위젯
  Widget _buildPrimaryButton({
    required String text,
    required VoidCallback? onPressed,
    bool isSecondary = false,
    bool isLoading = false,
  }) {
    final accentColor = const Color(0xFF2E7D32);

    return SizedBox(
      width: double.infinity,
      height: 60,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: isSecondary ? Colors.grey.shade100 : accentColor,
          foregroundColor: isSecondary ? Colors.black87 : Colors.white,
          elevation: isSecondary ? 0 : 2,
          shadowColor: accentColor.withOpacity(0.3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: isLoading
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2.5,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    text,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              )
            : Text(
                text,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
      ),
    );
  }

  /// [화면 3] 완료 페이지 - 전문적인 UI
  Widget _buildCompleteStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? AppColors.darkBackground : Colors.white;
    final textColor = isDark
        ? AppColors.darkOnSurface
        : const Color(0xFF1B1B1B);
    final subTextColor = isDark
        ? AppColors.darkOnSurfaceVariant
        : const Color(0xFF6B7280);
    final accentColor = const Color(0xFF2E7D32);

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 성공 애니메이션 효과를 위한 컨테이너
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [accentColor, const Color(0xFF43A047)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: accentColor.withOpacity(0.35),
                        blurRadius: 30,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 60,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 40),
                // 제목
                Text(
                  '설정 완료!',
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 16),
                // 설명
                Text(
                  '이제부터 소중한 추억을\n자동으로 보관해드립니다',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    color: subTextColor,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 48),
                // 완료 안내 카드
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: isDark
                        ? AppColors.darkSurface
                        : const Color(0xFFF0FDF4),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: accentColor.withOpacity(0.2)),
                  ),
                  child: Column(
                    children: [
                      _buildCompleteCheckItem(
                        icon: Icons.cloud_done_rounded,
                        text: '자동 백업 활성화',
                        isDark: isDark,
                        accentColor: accentColor,
                      ),
                      const SizedBox(height: 12),
                      _buildCompleteCheckItem(
                        icon: Icons.shield_rounded,
                        text: '데이터 보호 설정 완료',
                        isDark: isDark,
                        accentColor: accentColor,
                      ),
                      const SizedBox(height: 12),
                      _buildCompleteCheckItem(
                        icon: Icons.notifications_active_rounded,
                        text: '알림 서비스 준비 완료',
                        isDark: isDark,
                        accentColor: accentColor,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // 하단 버튼
        Container(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          decoration: BoxDecoration(color: backgroundColor),
          child: SafeArea(
            top: false,
            child: _buildPrimaryButton(
              text: '시작하기',
              onPressed: _completeOnboarding,
            ),
          ),
        ),
      ],
    );
  }

  /// 완료 체크 아이템 위젯
  Widget _buildCompleteCheckItem({
    required IconData icon,
    required String text,
    required bool isDark,
    required Color accentColor,
  }) {
    final textColor = isDark
        ? AppColors.darkOnSurface
        : const Color(0xFF1B1B1B);

    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: accentColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: accentColor, size: 18),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: textColor,
            ),
          ),
        ),
        Icon(Icons.check_circle_rounded, color: accentColor, size: 22),
      ],
    );
  }
}
