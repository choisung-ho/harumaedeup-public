// lib/screens/connect_care_target_page.dart

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class ConnectCareTargetPage extends StatefulWidget {
  const ConnectCareTargetPage({super.key});

  @override
  State<ConnectCareTargetPage> createState() => _ConnectCareTargetPageState();
}

class _ConnectCareTargetPageState extends State<ConnectCareTargetPage> {
  final TextEditingController _codeController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _tryConnect() async {
    final inputCode = _codeController.text.trim();

    if (inputCode.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('연결 코드를 입력해주세요.')));
      return;
    }

    if (inputCode.length != 6) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('코드는 숫자 6자리여야 합니다.')));
      return;
    }

    setState(() => _isLoading = true);

    try {
      final firestore = FirebaseFirestore.instance;

      // 1. 입력한 코드로 '케어 대상자(시니어)' 찾기
      final querySnapshot = await firestore
          .collection('users')
          .where('connect_code', isEqualTo: inputCode)
          .limit(1)
          .get();

      if (querySnapshot.docs.isEmpty) {
        throw "존재하지 않는 코드입니다. 코드를 다시 확인해주세요.";
      }

      final targetDoc = querySnapshot.docs.first;
      final targetId = targetDoc.id;
      final targetData = targetDoc.data();

      // 시니어의 FCM 토큰 가져오기 (알림 전송용)
      final String? targetFcmToken = targetData['fcmToken'];

      if (targetData['role'] != 2 && targetData['role'] != '2') {
        throw "해당 코드는 케어 대상자의 코드가 아닙니다.";
      }

      // 2. 내 정보(보호자) 가져오기
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw "로그인 정보가 없습니다. 다시 로그인해주세요.";

      String myId = user.uid;
      final myDocRef = firestore.collection('users').doc(myId);
      final myDocSnapshot = await myDocRef.get();

      // ✅ [수정] 기기에서 직접 최신 토큰 가져오기 (훨씬 확실함!)
      String? myFcmToken = await FirebaseMessaging.instance.getToken();

      // 만약 내 문서가 없다면 생성 (안전장치)
      if (!myDocSnapshot.exists) {
        String myName = user.displayName ?? '보호자';
        await myDocRef.set({
          'name': myName,
          'email': user.email,
          'role': 1,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      // 3. [서버 업데이트] 양방향 연결 + FCM 토큰 교환

      // ✅ [수정] 내 문서(보호자)에 -> 대상자 ID & 대상자 FCM 토큰 저장
      await myDocRef.update({
        'seniorId': targetId,
        'is_connected': true,
        'seniorFcmToken': targetFcmToken, // 상대방 토큰 저장
      });

      // ✅ [수정] 대상자 문서(시니어)에 -> 보호자 ID & 보호자 FCM 토큰 저장
      await firestore.collection('users').doc(targetId).update({
        'guardianId': myId,
        'is_connected': true,
        'guardianFcmToken': myFcmToken, // 내 토큰 저장
      });

      // 4. 로컬 저장
      final prefs = await SharedPreferences.getInstance();
      String prefsKey = user.email ?? myId;
      await prefs.setString('user_care_target_id_$prefsKey', targetId);
      await prefs.setBool('user_care_$prefsKey', true);

      setState(() => _isLoading = false);

      if (!mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text("연결 성공"),
          content: Text(
            "'${targetData['name'] ?? '어르신'}'님과 연결되었습니다.\n이제 보호자 모드를 시작합니다.",
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context, true);
              },
              child: const Text("확인"),
            ),
          ],
        ),
      );
    } catch (e) {
      setState(() => _isLoading = false);
      String msg = e.toString();
      if (msg.contains("Exception:")) msg = msg.replaceAll("Exception: ", "");
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("케어 대상자 연결")),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "케어 대상자의\n초대 코드를 입력해주세요.",
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            const Text(
              "어르신 앱의 [설정] 화면 상단에서 코드를 확인할 수 있습니다.",
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
            const SizedBox(height: 30),
            TextField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '초대 코드 6자리',
                hintText: '예: 123456',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                prefixIcon: const Icon(Icons.vpn_key),
                filled: true,
                fillColor: Theme.of(context).brightness == Brightness.dark
                    ? Colors.grey[800]
                    : Colors.grey[100],
              ),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _tryConnect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text(
                        "연결하기",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
