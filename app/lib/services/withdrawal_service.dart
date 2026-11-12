// lib/services/withdrawal_service.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:workmanager/workmanager.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../screens/login_page.dart';
import '../main.dart';

class WithdrawalService {
  static Future<void> deleteAccount(BuildContext context) async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // 🔥 삭제에 필요한 정보를 먼저 확보 (계정 삭제 후에는 접근 불가)
    final String email = (user.email ?? "").trim().toLowerCase(); // 소문자 강제 통일
    final String uid = user.uid;

    try {
      // 1. 구글 사용자라면 재인증부터 수행
      if (user.providerData.any((info) => info.providerId == 'google.com')) {
        bool reAuthSuccess = await _reauthenticateWithGoogle();
        if (!reAuthSuccess) return;
      }

      _showSafeLoadingDialog();

      // 2. 백그라운드 서비스 중지
      try {
        await Workmanager().cancelAll();
        FlutterBackgroundService().invoke("stopService");
      } catch (e) {
        debugPrint("서비스 중지 무시: $e");
      }

      // 3. 데이터 삭제 프로세스 실행 (이메일과 UID 모두 전달)
      // 🔥 반드시 계정(Auth)을 지우기 전에 DB를 먼저 지워야 권한 문제가 없습니다.
      await _performCleanup(email, uid).timeout(
        const Duration(seconds: 20),
        onTimeout: () => debugPrint("⏰ 데이터 삭제 시간 초과 - 다음 단계로"),
      );

      // 4. 🔥 모든 데이터가 지워진 후 마지막에 계정 삭제
      await user.delete();
      debugPrint("✅ Firebase Auth 계정 삭제 완료");

      _closeSafeLoadingDialog();
      _navigateToLoginSafe("회원 탈퇴가 완료되었습니다.");
    } on FirebaseAuthException catch (e) {
      _closeSafeLoadingDialog();
      if (e.code == 'requires-recent-login') {
        _navigateToLoginSafe("보안을 위해 다시 로그인한 뒤 탈퇴를 진행해주세요.");
      }
    } catch (e) {
      _closeSafeLoadingDialog();
      debugPrint("🚨 일반 에러: $e");
    }
  }

  /// [핵심 로직] Firestore 및 Storage 데이터 완전 삭제
  static Future<void> _performCleanup(String email, String uid) async {
    // 1. 보호자 관계 해제
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .where('careTargetId', isEqualTo: email) // 이메일 기준
          .get();
      for (var doc in snapshot.docs) {
        await doc.reference.update({'careTargetId': FieldValue.delete()});
      }
    } catch (e) {
      debugPrint("보호자 해제 실패: $e");
    }

    // 2. Firestore 데이터 삭제 (하위 컬렉션 포함)
    // 🔥 사용자 문서 ID가 이메일인 경우와 UID인 경우 모두 대응
    try {
      await _recursiveDeleteDocument('users', email);
      await _recursiveDeleteDocument('locations', email);
      debugPrint("🗑️ Firestore 데이터 삭제 완료 ($email)");
    } catch (e) {
      debugPrint("Firestore 삭제 실패: $e");
    }

    // 3. Firebase Storage 파일 삭제
    try {
      final ref = FirebaseStorage.instance.ref().child('Users/$uid');
      final list = await ref.listAll();
      for (var item in list.items) {
        await item.delete();
      }
    } catch (e) {
      debugPrint("Storage 삭제 실패: $e");
    }

    // 4. 로컬 데이터 초기화
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (Hive.isBoxOpen('location_logs')) {
      await Hive.box('location_logs').clear();
    }

    // 5. 구글 로그아웃
    final googleSignIn = GoogleSignIn();
    if (await googleSignIn.isSignedIn()) {
      await googleSignIn.disconnect();
    }
  }

  /// Firestore 문서와 그 하위 컬렉션을 모두 찾아 지우는 함수
  static Future<void> _recursiveDeleteDocument(
    String collection,
    String docId,
  ) async {
    if (docId.isEmpty) return;
    final docRef = FirebaseFirestore.instance.collection(collection).doc(docId);

    // 삭제할 하위 컬렉션들
    List<String> subCollections = [
      'diaries',
      'location_logs',
      'medication_logs',
      'safe_zones',
      'patient_logs',
      'history',
    ];

    for (String sub in subCollections) {
      final snapshot = await docRef.collection(sub).get();
      for (var doc in snapshot.docs) {
        await doc.reference.delete();
      }
    }
    await docRef.delete();
  }

  // --- 다이얼로그 및 내비게이션 함수 (기존과 동일) ---

  static Future<bool> _reauthenticateWithGoogle() async {
    try {
      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) return false;
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      await FirebaseAuth.instance.currentUser?.reauthenticateWithCredential(
        credential,
      );
      return true;
    } catch (e) {
      return false;
    }
  }

  static void _showSafeLoadingDialog() {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(color: Color(0xFF81C784)),
      ),
    );
  }

  static void _closeSafeLoadingDialog() {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    Navigator.of(context, rootNavigator: true).pop();
  }

  static void _navigateToLoginSafe(String message) {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const LoginPage()),
      (route) => false,
    );
  }
}
