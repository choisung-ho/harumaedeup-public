// lib/services/fcm_token_sync_service.dart
// FCM 토큰 동기화 서비스 - 보호자/시니어 연결 시 토큰 자동 동기화

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// FCM 토큰 동기화 서비스
///
/// 보호자와 시니어가 연결되어 있을 때, 한 쪽의 FCM 토큰이 변경되면
/// 상대방 문서의 토큰 필드도 자동으로 업데이트합니다.
///
/// 데이터 구조:
/// - 보호자(role: 1): seniorId, seniorFcmToken 필드 보유
/// - 시니어(role: 2): guardianId, guardianFcmToken 필드 보유
class FcmTokenSyncService {
  static final FcmTokenSyncService _instance = FcmTokenSyncService._internal();
  factory FcmTokenSyncService() => _instance;
  FcmTokenSyncService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  StreamSubscription<String>? _tokenRefreshSubscription;
  String? _lastKnownToken;
  bool _isInitialized = false;

  /// 서비스 초기화 - 앱 시작 시 호출
  Future<void> init() async {
    if (_isInitialized) {
      debugPrint('🔄 FcmTokenSyncService: 이미 초기화됨');
      return;
    }

    debugPrint('🚀 FcmTokenSyncService: 초기화 시작');

    // 현재 로그인된 사용자 확인
    final user = _auth.currentUser;
    if (user == null) {
      debugPrint('⚠️ FcmTokenSyncService: 로그인된 사용자 없음');
      return;
    }

    // 1. 현재 FCM 토큰 가져와서 동기화
    final currentToken = await _messaging.getToken();
    if (currentToken != null) {
      _lastKnownToken = currentToken;
      await _updateTokenAndSync(user.uid, currentToken);
    }

    // 2. 토큰 갱신 리스너 등록
    _tokenRefreshSubscription = _messaging.onTokenRefresh.listen((newToken) {
      debugPrint('🔄 FCM 토큰 갱신 감지: $newToken');
      _handleTokenRefresh(newToken);
    });

    _isInitialized = true;
    debugPrint('✅ FcmTokenSyncService: 초기화 완료');
  }

  /// 토큰 갱신 처리
  Future<void> _handleTokenRefresh(String newToken) async {
    final user = _auth.currentUser;
    if (user == null) {
      debugPrint('⚠️ 토큰 갱신 처리 실패: 로그인된 사용자 없음');
      return;
    }

    // 토큰이 실제로 변경되었는지 확인
    if (_lastKnownToken == newToken) {
      debugPrint('ℹ️ 토큰 동일 - 업데이트 스킵');
      return;
    }

    _lastKnownToken = newToken;
    await _updateTokenAndSync(user.uid, newToken);
  }

  /// 내 토큰 업데이트 및 연결된 상대방 문서에도 동기화
  Future<void> _updateTokenAndSync(String uid, String newToken) async {
    try {
      debugPrint('🔄 토큰 동기화 시작: uid=$uid');

      // 1. 내 문서 가져오기
      final myDoc = await _firestore.collection('users').doc(uid).get();

      if (!myDoc.exists) {
        debugPrint('❌ 사용자 문서를 찾을 수 없음: $uid');
        return;
      }

      final myData = myDoc.data()!;
      final int? role = myData['role'] as int?;
      final String? currentToken = myData['fcmToken'] as String?;

      // 토큰이 동일하면 업데이트 불필요
      if (currentToken == newToken) {
        debugPrint('ℹ️ Firestore 토큰 동일 - 업데이트 스킵');
        return;
      }

      // 2. 내 문서에 토큰 업데이트
      await _firestore.collection('users').doc(uid).update({
        'fcmToken': newToken,
        'lastTokenUpdate': FieldValue.serverTimestamp(),
      });
      debugPrint('✅ 내 FCM 토큰 업데이트 완료');

      // 3. 역할에 따라 연결된 상대방 문서도 업데이트
      if (role == 1) {
        // 보호자인 경우 → 시니어의 guardianFcmToken 업데이트
        await _syncToSenior(myData, newToken);
      } else if (role == 2) {
        // 시니어인 경우 → 보호자의 seniorFcmToken 업데이트
        await _syncToGuardian(myData, newToken);
      } else {
        debugPrint('⚠️ 알 수 없는 역할: $role');
      }
    } catch (e) {
      debugPrint('❌ 토큰 동기화 실패: $e');
    }
  }

  /// 보호자의 토큰이 변경되면 시니어 문서의 guardianFcmToken 업데이트
  Future<void> _syncToSenior(
    Map<String, dynamic> guardianData,
    String newToken,
  ) async {
    final String? seniorId = guardianData['seniorId'] as String?;
    final bool isConnected = guardianData['is_connected'] as bool? ?? false;

    if (!isConnected || seniorId == null || seniorId.isEmpty) {
      debugPrint('ℹ️ 연결된 시니어 없음 - 동기화 스킵');
      return;
    }

    try {
      // 시니어 문서의 guardianFcmToken 업데이트
      await _firestore.collection('users').doc(seniorId).update({
        'guardianFcmToken': newToken,
      });
      debugPrint('✅ 시니어($seniorId)의 guardianFcmToken 동기화 완료');
    } catch (e) {
      debugPrint('❌ 시니어 토큰 동기화 실패: $e');
    }
  }

  /// 시니어의 토큰이 변경되면 보호자 문서의 seniorFcmToken 업데이트
  Future<void> _syncToGuardian(
    Map<String, dynamic> seniorData,
    String newToken,
  ) async {
    final String? guardianId = seniorData['guardianId'] as String?;
    final bool isConnected = seniorData['is_connected'] as bool? ?? false;

    if (!isConnected || guardianId == null || guardianId.isEmpty) {
      debugPrint('ℹ️ 연결된 보호자 없음 - 동기화 스킵');
      return;
    }

    try {
      // 보호자 문서의 seniorFcmToken 업데이트
      await _firestore.collection('users').doc(guardianId).update({
        'seniorFcmToken': newToken,
      });
      debugPrint('✅ 보호자($guardianId)의 seniorFcmToken 동기화 완료');
    } catch (e) {
      debugPrint('❌ 보호자 토큰 동기화 실패: $e');
    }
  }

  /// 로그인 시 토큰 업데이트 및 상대방 동기화
  /// login_page.dart에서 로그인 성공 직후 호출
  Future<void> updateTokenOnLogin(String uid) async {
    try {
      debugPrint('🔐 [로그인] 토큰 업데이트 시작: uid=$uid');

      // 1. 최신 FCM 토큰 가져오기
      final token = await _messaging.getToken();
      if (token == null) {
        debugPrint('❌ FCM 토큰을 가져올 수 없음');
        return;
      }

      debugPrint('📱 FCM 토큰: ${token.substring(0, 20)}...');

      // 2. 내 문서 가져오기
      final myDoc = await _firestore.collection('users').doc(uid).get();
      if (!myDoc.exists) {
        debugPrint('❌ 사용자 문서를 찾을 수 없음: $uid');
        return;
      }

      final myData = myDoc.data()!;
      final int? role = myData['role'] as int?;
      final bool isConnected = myData['is_connected'] as bool? ?? false;

      // 3. 내 문서에 fcmToken 업데이트 (무조건 업데이트!)
      await _firestore.collection('users').doc(uid).update({
        'fcmToken': token,
        'lastTokenUpdate': FieldValue.serverTimestamp(),
      });
      debugPrint('✅ users/$uid/fcmToken 업데이트 완료');

      // 4. 연결된 상대가 있으면 상대방 필드에도 내 토큰 업데이트
      if (!isConnected) {
        debugPrint('ℹ️ 연결된 상대 없음 - 내 토큰만 업데이트됨');
        return;
      }

      if (role == 1) {
        // 보호자 → 시니어의 guardianFcmToken 업데이트
        final seniorId = myData['seniorId'] as String?;
        if (seniorId != null && seniorId.isNotEmpty) {
          await _firestore.collection('users').doc(seniorId).update({
            'guardianFcmToken': token,
          });
          debugPrint('✅ users/$seniorId/guardianFcmToken 업데이트 완료');
        }
      } else if (role == 2) {
        // 시니어 → 보호자의 seniorFcmToken 업데이트
        final guardianId = myData['guardianId'] as String?;
        if (guardianId != null && guardianId.isNotEmpty) {
          await _firestore.collection('users').doc(guardianId).update({
            'seniorFcmToken': token,
          });
          debugPrint('✅ users/$guardianId/seniorFcmToken 업데이트 완료');
        }
      }

      debugPrint('✅ [로그인] 토큰 업데이트 및 동기화 완료');
    } catch (e) {
      debugPrint('❌ [로그인] 토큰 업데이트 실패: $e');
    }
  }

  /// 수동으로 토큰 동기화 강제 실행
  /// 연결 직후나 앱 재시작 시 호출 가능
  Future<void> forceSyncToken() async {
    final user = _auth.currentUser;
    if (user == null) {
      debugPrint('⚠️ forceSyncToken 실패: 로그인된 사용자 없음');
      return;
    }

    final token = await _messaging.getToken();
    if (token == null) {
      debugPrint('⚠️ forceSyncToken 실패: FCM 토큰 없음');
      return;
    }

    debugPrint('🔄 강제 토큰 동기화 시작');
    await _updateTokenAndSync(user.uid, token);
  }

  /// 연결 성공 후 양방향 토큰 동기화
  /// ConnectCareTargetPage에서 연결 성공 시 호출
  Future<void> syncTokensAfterConnection({
    required String myUid,
    required String partnerUid,
  }) async {
    try {
      debugPrint('🔄 연결 후 토큰 동기화 시작: myUid=$myUid, partnerUid=$partnerUid');

      // 내 최신 토큰 가져오기
      final myToken = await _messaging.getToken();

      // 상대방 문서에서 토큰 가져오기
      final partnerDoc = await _firestore
          .collection('users')
          .doc(partnerUid)
          .get();
      final partnerToken = partnerDoc.data()?['fcmToken'] as String?;

      // 내 문서 가져오기
      final myDoc = await _firestore.collection('users').doc(myUid).get();
      final int? myRole = myDoc.data()?['role'] as int?;

      if (myRole == 1) {
        // 나 = 보호자
        // 내 문서에 seniorFcmToken 저장
        // 시니어 문서에 guardianFcmToken 저장
        await _firestore.collection('users').doc(myUid).update({
          'fcmToken': myToken,
          'seniorFcmToken': partnerToken,
          'lastTokenUpdate': FieldValue.serverTimestamp(),
        });
        await _firestore.collection('users').doc(partnerUid).update({
          'guardianFcmToken': myToken,
        });
        debugPrint('✅ 보호자-시니어 토큰 교환 완료');
      } else if (myRole == 2) {
        // 나 = 시니어
        // 내 문서에 guardianFcmToken 저장
        // 보호자 문서에 seniorFcmToken 저장
        await _firestore.collection('users').doc(myUid).update({
          'fcmToken': myToken,
          'guardianFcmToken': partnerToken,
          'lastTokenUpdate': FieldValue.serverTimestamp(),
        });
        await _firestore.collection('users').doc(partnerUid).update({
          'seniorFcmToken': myToken,
        });
        debugPrint('✅ 시니어-보호자 토큰 교환 완료');
      }
    } catch (e) {
      debugPrint('❌ 연결 후 토큰 동기화 실패: $e');
    }
  }

  /// 서비스 정리 (앱 종료 시)
  void dispose() {
    _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
    _isInitialized = false;
    debugPrint('🛑 FcmTokenSyncService: dispose 완료');
  }
}
