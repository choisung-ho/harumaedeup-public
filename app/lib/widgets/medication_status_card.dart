// medication_status_card.dart

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class MedicationStatusCard extends StatefulWidget {
  final String careTargetId; // 환자 UID
  final String careTargetName; // 환자 이름
  final String? careTargetFcmToken; // 환자 토큰

  const MedicationStatusCard({
    super.key,
    required this.careTargetId,
    required this.careTargetName,
    this.careTargetFcmToken,
  });

  @override
  State<MedicationStatusCard> createState() => _MedicationStatusCardState();
}

class _MedicationStatusCardState extends State<MedicationStatusCard> {
  // [알림 발송 함수]
  Future<void> _sendPushNotification() async {
    if (widget.careTargetFcmToken == null) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("환자 토큰이 없습니다.")));
      return;
    }

    try {
      // ⚠️ Firebase Console에서 복사한 서버 키를 여기에 넣으세요!
      String serverKey = '여기에_FIREBASE_SERVER_KEY_입력';

      var jsonBody = {
        "to": widget.careTargetFcmToken,
        "priority": "high",
        "notification": {
          "title": "💊 약 드실 시간이에요!",
          "body": "${widget.careTargetName}님, 잊지 말고 약 챙겨 드세요!",
        },
        "data": {
          "payload": "medication",
          "click_action": "FLUTTER_NOTIFICATION_CLICK"
        }
      };

      await http.post(
        Uri.parse('https://endpoint-5.example.invalid/fcm/send'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'key=$serverKey',
        },
        body: json.encode(jsonBody),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("알림을 보냈습니다! 🔔"), backgroundColor: Colors.blueAccent),
        );
      }
    } catch (e) {
      debugPrint("전송 실패: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    // 실시간 데이터 감지
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(widget.careTargetId)
          .collection('medication_logs')
          .orderBy('timestamp', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        // 1. 데이터 확인 로직
        bool isTakenToday = false;
        String? takenTime;
        String todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

        if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
          var todayLog = snapshot.data!.docs.where((doc) {
            return (doc.data() as Map<String, dynamic>)['date'] == todayStr;
          }).firstOrNull;

          if (todayLog != null) {
            final data = todayLog.data() as Map<String, dynamic>;
            if (data['isTaken'] == true) {
              isTakenToday = true;
              Timestamp ts = data['timestamp'];
              takenTime = DateFormat('a h:mm', 'ko_KR').format(ts.toDate());
            }
          }
        }

        // 2. UI 그리기 (녹색 박스 대체)
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            // 약 먹었으면 초록색, 안 먹었으면 주황색으로 강조
            color: isTakenToday ? const Color(0xFF81C784) : const Color(0xFFFFCC80),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.grey.withOpacity(0.2),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 상단 제목
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    isTakenToday ? "✅ 복용 완료" : "⚠️ 아직 안 드셨어요",
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  // 새로고침 아이콘 대신 상태 아이콘 표시
                  Icon(
                    isTakenToday ? Icons.sentiment_satisfied_alt : Icons.notifications_active,
                    color: Colors.white,
                    size: 30,
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // 내용 (시간 또는 버튼)
              if (isTakenToday)
                Text(
                  "$takenTime에 드셨습니다.\n현재 상태가 아주 좋습니다!",
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "약을 드시도록 알림을 보내볼까요?",
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    const SizedBox(height: 15),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _sendPushNotification,
                        icon: const Icon(Icons.touch_app, color: Color(0xFFFFCC80)),
                        label: const Text(
                          "지금 알림 보내기",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFFE65100), // 진한 주황 텍스트
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}
