import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

class LocationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  static const String _hiveBoxName = 'location_logs';

  // ✅ [추가] 이탈 알림 중복 방지 키
  static const String _geofenceAlertSentKey = 'geofence_alert_sent';
  static const double _geofenceThreshold = 1000.0; // 1km 이탈 기준

  // 1. 서비스 초기화
  static Future<void> initialize() async {
    if (!Hive.isBoxOpen(_hiveBoxName)) {
      await Hive.initFlutter();
      await Hive.openBox(_hiveBoxName);
    }
    const AndroidInitializationSettings initSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notificationsPlugin.initialize(
      const InitializationSettings(android: initSettings),
    );
    debugPrint("✅ LocationService & Hive 초기화 완료");
  }

  static Future<void> saveLocationForArchive(Position pos) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final box = Hive.box(_hiveBoxName);

    // ✅ [수정] PatientHistoryPage와 키 이름 맞추기 (lat, lng)
    // ✅ [추가] 정확도(accuracy) 저장 필수! (이게 없으면 다 필터링됨)
    await box.add({
      'lat': pos.latitude, // latitude -> lat 변경
      'lng': pos.longitude, // longitude -> lng 변경
      'accuracy': pos.accuracy, // 🔥 필수 추가!
      'timestamp': DateTime.now().toIso8601String(),
      'speed': pos.speed,
    });

    await _updateRealtimeStatusForGuardian(pos, user);
    debugPrint("📍 [Hive] 데이터 누적 중 (현재 ${box.length}건 / 24시간 보관 모드)");
  }

  // LocationService.dart 수정

  static Future<void> _updateRealtimeStatusForGuardian(
    Position pos,
    User user,
  ) async {
    final String docId = user.uid; // UID 사용 (Project B 원칙)

    try {
      final serverTimestamp = FieldValue.serverTimestamp();

      // ✅ 업데이트할 데이터 (집주소 homeLat 등은 건드리지 않음)
      final Map<String, dynamic> statusData = {
        'currentLat': pos.latitude, // liveLat 대신 명확하게 currentLat 추천
        'currentLng': pos.longitude,
        'lastUpdated': serverTimestamp, // 언제 찍힌 좌표인지 중요!
        'isOnline': true, // 앱이 살아있음 표시
        'currentPlace': "이동 중", // 필요시 지오코딩으로 주소 변환 가능
      };

      // ✅ Users 컬렉션의 내 문서에 '병합(Merge)' 방식으로 업데이트
      // SetOptions(merge: true)가 있어야 기존 이름, 생년월일 등이 안 지워짐!
      await FirebaseFirestore.instance
          .collection('users')
          .doc(docId)
          .set(statusData, SetOptions(merge: true));

      debugPrint("📡 [Firestore] 실시간 위치 갱신 완료 (Users/$docId)");

      // ✅✅✅ [핵심 추가] 집과의 거리 확인 후 보호자에게 알림 전송 ✅✅✅
      await _checkGeofenceAndNotifyGuardian(pos, user);
    } catch (e) {
      debugPrint("❌ 위치 업데이트 실패: $e");
    }
  }

  /// ✅ [신규 추가] 집과의 거리 확인 후 보호자에게 알림 전송
  /// 시니어가 집에서 1km 이상 멀어지면 보호자에게 딱 한 번 알림 전송
  static Future<void> _checkGeofenceAndNotifyGuardian(
    Position pos,
    User user,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 1. 시니어의 집 위치 가져오기
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (!userDoc.exists) return;
      final userData = userDoc.data();
      if (userData == null) return;

      // ✅ homeLat/homeLng 또는 homeLatitude/homeLongitude 사용
      final double? homeLat =
          userData['homeLat']?.toDouble() ??
          userData['homeLatitude']?.toDouble();
      final double? homeLng =
          userData['homeLng']?.toDouble() ??
          userData['homeLongitude']?.toDouble();
      final String seniorName = userData['name'] ?? '시니어';

      if (homeLat == null || homeLng == null) return;

      // 2. 거리 계산
      final double distanceInMeters = _calculateDistance(
        pos.latitude,
        pos.longitude,
        homeLat,
        homeLng,
      );

      // 3. 이탈 여부 확인 및 알림 전송
      final bool alertAlreadySent =
          prefs.getBool(_geofenceAlertSentKey) ?? false;

      if (distanceInMeters > _geofenceThreshold) {
        // 집에서 1km 이상 이탈
        if (!alertAlreadySent) {
          // 아직 알림을 보내지 않은 상태 -> 보호자에게 알림 전송
          await _sendGeofenceAlertToGuardian(
            user.uid,
            seniorName,
            distanceInMeters,
          );
          await prefs.setBool(_geofenceAlertSentKey, true);
          debugPrint(
            "🚨 [Geofence] 이탈 알림 전송 완료: ${distanceInMeters.toStringAsFixed(0)}m",
          );
        }
      } else {
        // 집 근처로 복귀 -> 알림 플래그 초기화 (다음에 다시 이탈하면 알림 발송 가능)
        if (alertAlreadySent) {
          await prefs.setBool(_geofenceAlertSentKey, false);
          debugPrint("✅ [Geofence] 집 근처 복귀 - 알림 플래그 초기화");
        }
      }
    } catch (e) {
      debugPrint("⚠️ [Geofence] 체크 오류: $e");
    }
  }

  /// 두 좌표 간 거리 계산 (Haversine 공식)
  static double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double earthRadius = 6371000; // 지구 반지름 (미터)
    final double dLat = (lat2 - lat1) * pi / 180;
    final double dLon = (lon2 - lon1) * pi / 180;
    final double a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  /// 보호자에게 FCM 알림 전송
  static Future<void> _sendGeofenceAlertToGuardian(
    String seniorUid,
    String seniorName,
    double distanceInMeters,
  ) async {
    try {
      // 1. 시니어의 보호자 목록 가져오기
      final seniorDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(seniorUid)
          .get();

      if (!seniorDoc.exists) return;
      final seniorData = seniorDoc.data();
      if (seniorData == null) return;

      // guardians 필드에서 보호자 UID 목록 가져오기
      final List<dynamic>? guardians = seniorData['guardians'];
      if (guardians == null || guardians.isEmpty) {
        debugPrint("⚠️ [Geofence] 연결된 보호자 없음");
        return;
      }

      // 거리 텍스트 생성
      String distanceText;
      if (distanceInMeters < 1000) {
        distanceText = "${distanceInMeters.toStringAsFixed(0)}m";
      } else {
        distanceText = "${(distanceInMeters / 1000).toStringAsFixed(1)}km";
      }

      // 2. 각 보호자에게 알림 전송
      for (var guardianUid in guardians) {
        // 보호자의 FCM 토큰 가져오기
        final guardianDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(guardianUid)
            .get();

        if (!guardianDoc.exists) continue;
        final guardianData = guardianDoc.data();
        if (guardianData == null) continue;

        final String? fcmToken = guardianData['fcmToken'];
        if (fcmToken == null || fcmToken.isEmpty) {
          debugPrint("⚠️ [Geofence] 보호자 $guardianUid FCM 토큰 없음");
          continue;
        }

        // FCM 메시지 전송 (HTTP v1 API 사용 시 서버에서 처리하거나, Firestore 트리거 사용)
        // 여기서는 Firestore에 알림 문서를 생성하여 Cloud Functions에서 처리하도록 함
        await FirebaseFirestore.instance.collection('notifications').add({
          'type': 'geofence_alert',
          'targetUid': guardianUid,
          'targetFcmToken': fcmToken,
          'seniorUid': seniorUid,
          'seniorName': seniorName,
          'title': '🚨 $seniorName님 이탈 알림',
          'body': '$seniorName님이 집에서 $distanceText 떨어져 있습니다.',
          'distance': distanceInMeters,
          'createdAt': FieldValue.serverTimestamp(),
          'sent': false, // Cloud Functions에서 전송 후 true로 변경
        });

        debugPrint("📤 [Geofence] 보호자 $guardianUid에게 알림 요청 생성");
      }
    } catch (e) {
      debugPrint("❌ [Geofence] 보호자 알림 전송 오류: $e");
    }
  }

  // 📦 [Track 2] 과거 기록 저장용 (Storage 업로드 + 24시간 로컬 유지)
  // 🔥 [핵심 수정] 백그라운드 작업 시 로그인이 풀릴 수 있으므로 manualUserKey를 인자로 받음
  static Future<void> uploadToStorage({String? manualUserKey}) async {
    final box = Hive.box(_hiveBoxName);
    if (box.isEmpty) {
      debugPrint("📂 [Archive] 저장할 로컬 데이터가 없습니다.");
      return;
    }

    // 1. 업로드할 유저 ID 결정 (매개변수 우선 -> 없으면 현재 로그인 유저)
    String? targetId = manualUserKey;
    if (targetId == null) {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        targetId = user.uid;
      }
    }

    // 2. ID 식별 불가 시 중단 (백그라운드 에러 방지)
    if (targetId == null) {
      debugPrint("❌ [Archive] 유저 식별 실패 (로그인 정보 없음)");
      return;
    }

    try {
      final String date = DateFormat(
        'yyyy-MM-dd',
      ).format(DateTime.now()); // 파일명 충돌 방지
      // 경로: Users / ID / source / locations / 날짜.json
      final String storagePath = "Users/$targetId/source/locations/$date.json";

      // 현재 박스에 있는 모든 데이터(최대 24시간 분량)를 가져와서 업로드
      final List<dynamic> allLogs = box.values.toList();

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$date.json');
      await file.writeAsString(jsonEncode(allLogs));

      // Firebase Storage 업로드
      await FirebaseStorage.instance.ref(storagePath).putFile(file);
      debugPrint(
        "🚀 [Storage] 업로드 성공: $storagePath (데이터 ${allLogs.length}건 포함)",
      );

      // 🔥 [핵심 변경] 전체 삭제(clear) 대신, 24시간 지난 데이터만 골라서 삭제
      await _deleteOldData(box);
    } catch (e) {
      debugPrint("❌ [Storage] 업로드 실패: $e");
    }
  }

  // 🧹 [신규 추가] 24시간이 지난 데이터만 삭제하는 함수
  static Future<void> _deleteOldData(Box box) async {
    final now = DateTime.now();
    final List<dynamic> keysToDelete = [];

    for (var key in box.keys) {
      final data = box.get(key);
      if (data != null && data['timestamp'] != null) {
        try {
          DateTime logTime = DateTime.parse(data['timestamp']);
          // 현재 시간보다 24시간 이전이면 삭제 리스트에 추가
          if (now.difference(logTime).inHours >= 24) {
            keysToDelete.add(key);
          }
        } catch (e) {
          // 날짜 형식이 이상한 데이터도 삭제
          keysToDelete.add(key);
        }
      }
    }

    if (keysToDelete.isNotEmpty) {
      await box.deleteAll(keysToDelete);
      debugPrint("🧹 오래된 데이터(24시간 경과) ${keysToDelete.length}건을 로컬에서 삭제했습니다.");
    } else {
      debugPrint("✨ 24시간 이내 데이터는 로컬에 유지됩니다.");
    }
  }

  // 4. 지오편싱 알림 (보호자 모드에서만 동작 - 시니어 기기에서는 로컬 알림 미표시)
  static Future<void> sendGeofenceAlert(double distance) async {
    // ✅ [수정] 시니어 기기에서는 로컬 알림을 표시하지 않음
    // 이탈 알림은 SafetyMonitorService가 Firestore 상태를 변경하고,
    // 보호자 기기에서 GuardianHomePage가 감지하여 다이얼로그로 표시합니다.
    debugPrint(
      '⚠️ [sendGeofenceAlert] 시니어 기기 로컬 알림 대신 보호자에게만 Firestore/FCM으로 전송됩니다.',
    );
  }
}
