import 'dart:async';
import 'dart:ui';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:workmanager/workmanager.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'firebase_options.dart';
import 'screens/login_page.dart';
import 'screens/home_page.dart';
import 'screens/guardian_home_page.dart';
import 'screens/guardian_map_page.dart';
import 'screens/permission_request_page.dart';
import 'screens/medication_fullscreen_page.dart';
import 'screens/splash_screen.dart';
import 'services/location_service.dart';
import 'screens/medication_check_page.dart';
import 'services/medication_service.dart';
import 'services/archive_service.dart';
import 'services/auto_upload_service.dart';
import 'services/sms_listener_service.dart';
import 'services/permission_service.dart';
import 'services/fcm_manager.dart';
import 'services/background_service.dart';
import 'services/safety_monitor_service.dart'; // ✅ [추가] 이탈 감시 서비스 임포트

import 'theme_state.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// [1] 백그라운드 정기 작업 (Workmanager)
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      DartPluginRegistrant.ensureInitialized();
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }

      final prefs = await SharedPreferences.getInstance();
      String? currentKey =
          prefs.getString('currentEmail') ?? prefs.getString('currentUser');

      if (currentKey != null) {
        if (task == "location_upload_task") {
          await LocationService.initialize();
          await LocationService.uploadToStorage();
        }
        if (task == "hourly_archive_task") {
          // 데이터 타입 혼선을 막기 위해 .get() 후 toString() 처리
          String role = (prefs.get('user_role_$currentKey') ?? '0').toString();
          if (role == '2') await ArchiveService.archiveHourly(currentKey);
        }
      }
    } catch (e) {
      return Future.value(false);
    }
    return Future.value(true);
  });
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }
  final String? messageType = message.data['type'];

  // ✅ [수정] 긴급 이탈 알림 처리 (보호자 모드에서만 동작)
  if (messageType == 'emergency') {
    final prefs = await SharedPreferences.getInstance();
    final savedUid = prefs.getString('currentUser');
    dynamic rawRole =
        prefs.get('role') ?? prefs.get('user_role_$savedUid') ?? '0';
    String role = rawRole.toString();

    // ✅ 보호자(role=1)일 때만 알림 표시
    if (role == '1') {
      await _showBackgroundEmergencyNotification(message);
    } else {
      debugPrint('🚫 [백그라운드] 시니어 모드에서는 긴급 알림을 표시하지 않습니다.');
    }
  }
  // 약 복용 알림 처리
  else if ([
    'medication',
    'medication_alert',
    'medication_alarm',
  ].contains(messageType)) {
    await _showBackgroundMedicationNotification(message);
  }
}

// ✅ [추가] 긴급 이탈 알림 표시 (백그라운드용)
Future<void> _showBackgroundEmergencyNotification(RemoteMessage message) async {
  final plugin = FlutterLocalNotificationsPlugin();
  final String patientName = message.data['patientName'] ?? '대상자';
  final String alertMessage = message.data['alertMessage'] ?? '안전 구역을 벗어났습니다!';
  final String title = message.notification?.title ?? '🚨 비상: $patientName님 이탈';
  final String body = message.notification?.body ?? alertMessage;

  const androidDetails = AndroidNotificationDetails(
    'emergency_channel_id', // Cloud Functions와 동일한 채널 ID
    '긴급 이탈 알림',
    channelDescription: '환자가 안전 구역을 벗어났을 때 울립니다.',
    importance: Importance.max,
    priority: Priority.max,
    fullScreenIntent: true, // 전체화면 표시
    category: AndroidNotificationCategory.alarm,
    playSound: true,
    enableVibration: true,
    visibility: NotificationVisibility.public,
    color: Color(0xFFFF0000),
  );

  await plugin.show(
    777, // 긴급 알림 고정 ID
    title,
    body,
    const NotificationDetails(android: androidDetails),
    payload: 'emergency|${message.data['patientId']}|$patientName',
  );
}

Future<void> _showBackgroundMedicationNotification(
  RemoteMessage message,
) async {
  final plugin = FlutterLocalNotificationsPlugin();
  final String title =
      message.notification?.title ?? message.data['title'] ?? '💊 약 드실 시간이에요!';
  final String body =
      message.notification?.body ?? message.data['body'] ?? '약을 드셨나요?';

  const androidDetails = AndroidNotificationDetails(
    'medication_fullscreen_channel',
    '약 복용 알림',
    importance: Importance.max,
    priority: Priority.high,
    fullScreenIntent: true,
    category: AndroidNotificationCategory.alarm,
  );

  await plugin.show(
    999,
    title,
    body,
    const NotificationDetails(android: androidDetails),
    payload:
        'medication|${message.data['alarm_id']}|${message.data['medication_name']}|${message.data['retry_count'] ?? '0'}',
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();

  try {
    await dotenv.load(fileName: ".env");
  } catch (_) {}

  tz.initializeTimeZones();
  try {
    final String timeZoneName = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timeZoneName));
  } catch (_) {
    tz.setLocalLocation(tz.getLocation('UTC'));
  }

  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
  } catch (e) {
    debugPrint("⚠️ Firebase already initialized: $e");
  }

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await LocationService.initialize();
  await initializeService();

  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  await Workmanager().registerPeriodicTask(
    "location_upload_task",
    "location_upload_task",
    frequency: const Duration(hours: 1),
  );

  await _initNotifications();
  await _createMedicationChannel();
  await loadThemeModeFromPrefs();

  final prefs = await SharedPreferences.getInstance();
  final bool isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
  String? savedUid = prefs.getString('currentUser');

  // ✅ [수정] 여러 키값을 모두 체크하여 역할을 정확히 판별 (가장 중요)
  dynamic rawRole =
      prefs.get('role') ?? prefs.get('user_role_$savedUid') ?? '0';
  String role = rawRole.toString();

  debugPrint("🔑 [System Start] UID: $savedUid, Detected Role: $role");

  Widget startPage;
  if (!isLoggedIn) {
    startPage = const LoginPage();
  } else {
    final shouldShowPermission = await PermissionService()
        .shouldShowPermissionPageForRole(role);
    if (shouldShowPermission) {
      startPage = PermissionRequestPage(role: role);
    } else {
      startPage = (role == '1') ? GuardianHomePage() : DiaryHomePage();
    }
  }

  runApp(DiaryApp(originalStartPage: SplashScreen(nextPage: startPage)));
  _initAfterStartup(role, isLoggedIn);
}

Future<void> _initAfterStartup(String? role, bool isLoggedIn) async {
  if (isLoggedIn) await setupFCM();

  // ✅ [수정] '2'라는 문자열과 숫자를 모두 고려한 조건문
  if (role == '2' || role == '2.0') {
    debugPrint("👴 [Senior Mode] 이탈 감시 엔진 및 자동 업로드 가동");

    // 1. 위치 이탈 감시 서비스 가동 (이게 핵심!)
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      SafetyMonitorService().startMonitoring(uid);
    }

    // 2. 백그라운드 서비스 가동
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) await service.startService();

    // 3. 기타 시니어 전용 서비스 초기화
    await AutoUploadService().initialize();
    await SmsListenerService().initialize();
    await FCMManager().init();
  } else {
    debugPrint("👨‍👩‍👧 [Guardian Mode] 보호자 모드 활성화");
  }

  FCMManager.navigatorKey = navigatorKey;
  try {
    await NaverMapSdk.instance.initialize();
  } catch (_) {}
}

class DiaryApp extends StatefulWidget {
  final Widget originalStartPage;
  const DiaryApp({super.key, required this.originalStartPage});
  @override
  State<DiaryApp> createState() => _DiaryAppState();
}

class _DiaryAppState extends State<DiaryApp> with WidgetsBindingObserver {
  StreamSubscription<DocumentSnapshot>? _loginMonitorSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startDuplicateLoginMonitor();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loginMonitorSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _triggerAutoUploadIfSenior();
  }

  Future<void> _triggerAutoUploadIfSenior() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final prefs = await SharedPreferences.getInstance();
    final role = (prefs.get('user_role_${user.uid}') ?? '0').toString();
    if (role == '2') await AutoUploadService().scanAndUploadAll();
  }

  Future<void> _startDuplicateLoginMonitor() async {
    // ✅ [버그 수정] Firebase Auth 캐시와 SharedPreferences를 모두 확인
    // Firebase Auth는 앱 재시작 후에도 이전 세션이 남아있을 수 있음.
    // SharedPreferences의 isLoggedIn과 currentUser가 일치할 때만 모니터 시작.
    final prefs = await SharedPreferences.getInstance();
    final bool isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
    final String? savedUid = prefs.getString('currentUser');

    if (!isLoggedIn || savedUid == null || savedUid.isEmpty) {
      debugPrint("🔒 [DuplicateLogin] 로그인 상태 아님 → 모니터 스킵");
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // ✅ [핵심] Firebase Auth의 UID와 SharedPreferences의 UID가 다르면 모니터 안 함
    // (다른 계정의 캐시가 남아있는 경우 방지)
    if (user.uid != savedUid) {
      debugPrint(
        "⚠️ [DuplicateLogin] Firebase Auth UID(${user.uid})와 저장된 UID($savedUid) 불일치 → 모니터 스킵",
      );
      return;
    }

    final deviceInfo = DeviceInfoPlugin();
    String deviceId = Platform.isAndroid
        ? (await deviceInfo.androidInfo).id
        : (await deviceInfo.iosInfo).identifierForVendor ?? 'unknown';

    await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
      'deviceId': deviceId,
      'lastLogin': FieldValue.serverTimestamp(),
    });

    _loginMonitorSub = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen((snap) async {
          if (snap.exists && snap.data()?['deviceId'] != deviceId) {
            _loginMonitorSub?.cancel();
            await FirebaseAuth.instance.signOut();
            final prefs = await SharedPreferences.getInstance();
            await prefs.clear();
            if (mounted && navigatorKey.currentContext != null) {
              _showLogoutDialog();
            }
          }
        });

    debugPrint("✅ [DuplicateLogin] 모니터 시작: UID=${user.uid}");
  }

  void _showLogoutDialog() {
    showDialog(
      context: navigatorKey.currentContext!,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("로그아웃 알림"),
        content: const Text("다른 기기에서 로그인하여\n현재 기기에서 로그아웃됩니다."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(
              context,
            ).pushNamedAndRemoveUntil('/login', (r) => false),
            child: const Text("확인", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, mode, _) => MaterialApp(
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: getLightTheme(),
        darkTheme: getDarkTheme(),
        routes: {
          '/login': (context) => const LoginPage(),
          // ✅ [추가] 긴급 알림 클릭 시 보호자 홈 라우트
          '/guardian_home': (context) {
            final args =
                ModalRoute.of(context)?.settings.arguments
                    as Map<String, dynamic>?;
            return GuardianHomePage(patientId: args?['patientId']);
          },
        },
        home: widget.originalStartPage,
      ),
    );
  }
}

Future<void> _initNotifications() async {
  const initSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await flutterLocalNotificationsPlugin.initialize(
    initSettings,
    onDidReceiveNotificationResponse: _handleNotificationResponse,
  );
}

void _handleNotificationResponse(NotificationResponse response) {
  final payload = response.payload ?? '';

  // ✅ [수정] 긴급 이탈 알림 클릭 → 시니어 위치 보기(GuardianMapPage)로 직접 이동
  if (payload.startsWith('emergency')) {
    final parts = payload.split('|');
    final patientId = parts.length > 1 ? parts[1] : null;
    final patientName = parts.length > 2 ? parts[2] : '대상자';
    flutterLocalNotificationsPlugin.cancel(777);

    if (patientId != null) {
      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (context) =>
              GuardianMapPage(patientId: patientId, patientName: patientName),
        ),
      );
    } else {
      // patientId가 없으면 보호자 홈으로 이동
      navigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => GuardianHomePage()),
        (route) => false,
      );
    }
  }
  // 약 복용 알림 처리
  else if (payload.startsWith('medication')) {
    final parts = payload.split('|');
    flutterLocalNotificationsPlugin.cancel(999);
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => MedicationFullscreenPage(
          alarmId: parts.length > 1 ? parts[1] : null,
          medicationName: parts.length > 2 ? parts[2] : null,
          title: '💊 약 드실 시간이에요!',
          body: '건강을 위해 약을 드세요',
          retryCount: parts.length > 3 ? (int.tryParse(parts[3]) ?? 0) : 0,
        ),
      ),
    );
  }
}

Future<void> _createMedicationChannel() async {
  if (Platform.isAndroid) {
    final androidPlugin = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    // 약 복용 알림 채널
    const medicationChannel = AndroidNotificationChannel(
      'medication_fullscreen_channel',
      '약 복용 알림',
      importance: Importance.max,
    );
    await androidPlugin?.createNotificationChannel(medicationChannel);

    // ✅ [추가] 긴급 이탈 알림 채널 (FCM에서 사용하는 채널 ID와 동일)
    const emergencyChannel = AndroidNotificationChannel(
      'emergency_channel_id',
      '긴급 이탈 알림',
      description: '환자가 안전 구역을 벗어났을 때 울립니다.',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    );
    await androidPlugin?.createNotificationChannel(emergencyChannel);

    debugPrint("✅ [알림 채널] 약 복용 및 긴급 이탈 채널 생성 완료");
  }
}

Future<void> setupFCM() async {
  final token = await FirebaseMessaging.instance.getToken();
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (token != null && uid != null) {
    await FirebaseFirestore.instance.collection('users').doc(uid).set({
      'fcmToken': token,
    }, SetOptions(merge: true));
  }
}
