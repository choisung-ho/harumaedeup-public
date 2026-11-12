import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:firebase_auth/firebase_auth.dart'; // ✅ [추가]
import '../models/medication.dart'; // ✅ Ensure this import points to your model file

class MedicationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static const String _channelId = 'medication_alert_v3';
  static const String _channelName = 'Medication Alert (Sound)';

  // 1. [Existing Function] Save medication result to DB
  static Future<void> saveMedicationResult(
    bool isTaken,
    BuildContext context,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? currentKey =
          prefs.getString('currentEmail') ?? prefs.getString('currentUser');
      if (currentKey == null) return;

      String today = DateFormat('yyyy-MM-dd').format(DateTime.now());

      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentKey)
          .collection('medication_logs')
          .add({
            'date': today,
            'timestamp': FieldValue.serverTimestamp(),
            'isTaken': isTaken,
            'method': 'check_ui',
            'status': isTaken ? 'completed' : 'skipped',
          });
      debugPrint("✅ Medication log saved successfully");
    } catch (e) {
      debugPrint("❌ Failed to save log: $e");
    }
  }

  // ✅ [추가] FCM 전체화면에서 응답 시 호출되는 함수
  static Future<void> saveFcmMedicationResponse({
    required bool isTaken,
    String? alarmId,
    String? medicationName,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint("⚠️ 로그인된 사용자 없음");
        return;
      }

      final now = DateTime.now();
      final dateStr = DateFormat('yyyy-MM-dd').format(now);
      final status = isTaken ? 'taken' : 'missed';

      // 1. medication_logs에 저장
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('medication_logs')
          .add({
            'date': dateStr,
            'timestamp': FieldValue.serverTimestamp(),
            'isTaken': isTaken,
            'status': status,
            'method': 'fcm_fullscreen',
            'alarmId': alarmId,
            'medicationName': medicationName,
          });

      debugPrint("✅ FCM 약 복용 로그 저장: $status ($medicationName)");

      // 2. medicine_event의 last_response 업데이트
      if (alarmId != null && alarmId.isNotEmpty) {
        try {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('medicine_event')
              .doc(alarmId)
              .update({
                'last_response': status,
                'last_response_time': FieldValue.serverTimestamp(),
              });
          debugPrint("✅ medicine_event 업데이트 완료");
        } catch (e) {
          debugPrint("⚠️ medicine_event 업데이트 실패 (문서 없을 수 있음): $e");
        }
      }
    } catch (e) {
      debugPrint("❌ FCM 약 복용 응답 저장 실패: $e");
    }
  }

  // 2. [New Feature] Monitor Firestore for changes and auto-schedule alarms
  // This function must be called when the patient app starts (e.g., in home_page.dart)
  static void monitorMedications(String patientId) {
    debugPrint("📡 [Medication] Starting sync for patient: $patientId");

    FirebaseFirestore.instance
        .collection('users')
        .doc(patientId)
        .collection('medications')
        .snapshots() // 🔥 Listens for real-time updates
        .listen((snapshot) async {
          // (1) Cancel all existing alarms to prevent duplicates
          await _notificationsPlugin.cancelAll();
          debugPrint(
            "🔄 Refreshing alarm list... Found ${snapshot.docs.length} items.",
          );

          // (2) Fetch medications from DB and schedule alarms
          for (var doc in snapshot.docs) {
            try {
              Medication med = Medication.fromFirestore(doc);
              await _scheduleNotification(med);
            } catch (e) {
              debugPrint("⚠️ Failed to schedule alarm (Data Error): $e");
            }
          }
        });
  }

  // 3. [Upgraded] Schedule alarms based on specific days of the week
  static Future<void> _scheduleNotification(Medication med) async {
    final parts = med.time.split(':');
    final int hour = int.parse(parts[0]);
    final int minute = int.parse(parts[1]);

    // Schedule for each selected day (days list contains 1=Mon ... 7=Sun)
    for (int day in med.days) {
      // Generate a unique ID (Hashcode of ID + day index)
      int notificationId = med.id.hashCode + day;

      await _notificationsPlugin.zonedSchedule(
        notificationId,
        "💊 Time to take your medication!",
        "${med.name} - Please take it now. ($day ${med.time})", // Message includes time/day
        _nextInstanceOfDayAndTime(
          day,
          hour,
          minute,
        ), // Calculate next occurrence
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: 'Medication alerts set by guardian.',
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            category: AndroidNotificationCategory.alarm, // Alarm mode
            audioAttributesUsage: AudioAttributesUsage.alarm,
            fullScreenIntent: true, // Full-screen alert
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents
            .dayOfWeekAndTime, // ✅ Repeats weekly at this time
        payload: 'medication',
      );
    }
    debugPrint("✅ [Scheduled] ${med.name} - ${med.time} (Days: ${med.days})");
  }

  // 4. [Helper] Calculate the next occurrence for a specific day/time
  // (e.g., If today is Tuesday and we need Monday, calculate date for next Monday)
  static tz.TZDateTime _nextInstanceOfDayAndTime(
    int day,
    int hour,
    int minute,
  ) {
    tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime scheduledDate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );

    // Add days until the weekday matches the target 'day' (1=Mon ... 7=Sun)
    while (scheduledDate.weekday != day) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }

    // If the calculated time has already passed for today, move to next week
    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 7));
    }
    return scheduledDate;
  }
}
