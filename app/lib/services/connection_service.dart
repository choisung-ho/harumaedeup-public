import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// 보호자-시니어 연결 관계를 관리하는 서비스
///
/// 주요 기능:
/// - 사용자 역할 확인 (보호자/시니어)
/// - 연결된 상대방 UID 조회
/// - 연결 상태 실시간 모니터링
class ConnectionService {
  final FirebaseFirestore _firestore;

  ConnectionService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  /// 현재 로그인한 사용자의 역할을 확인합니다.
  ///
  /// [uid] 사용자 ID
  /// 반환: 1 (보호자) / 2 (시니어) / null (오류 또는 존재하지 않음)
  Future<int?> getUserRole(String uid) async {
    if (uid.isEmpty) {
      debugPrint('⚠️ ConnectionService: uid가 비어있습니다.');
      return null;
    }

    try {
      final doc = await _firestore.collection('users').doc(uid).get();

      if (!doc.exists) {
        debugPrint('⚠️ 사용자 문서를 찾을 수 없습니다: $uid');
        return null;
      }

      final data = doc.data();
      if (data == null) return null;

      final role = data['role'] as int?;
      debugPrint('📋 사용자 역할: $role (1=보호자, 2=시니어)');

      return role;
    } catch (e) {
      debugPrint('❌ 역할 조회 실패: $e');
      return null;
    }
  }

  /// 보호자가 연결된 시니어의 UID를 가져옵니다.
  ///
  /// [guardianUid] 보호자의 UID
  /// 반환: 시니어 UID 또는 null
  ///
  /// 사용 예시:
  /// ```dart
  /// String? seniorUid = await connectionService.getConnectedSeniorUid(myUid);
  /// if (seniorUid != null) {
  ///   // 시니어의 데이터에 접근
  /// }
  /// ```
  Future<String?> getConnectedSeniorUid(String guardianUid) async {
    if (guardianUid.isEmpty) {
      debugPrint('⚠️ ConnectionService: guardianUid가 비어있습니다.');
      return null;
    }

    try {
      final doc = await _firestore.collection('users').doc(guardianUid).get();

      if (!doc.exists) {
        debugPrint('⚠️ 보호자 문서를 찾을 수 없습니다: $guardianUid');
        return null;
      }

      final data = doc.data();
      if (data == null) return null;

      // 역할 확인
      final role = data['role'] as int?;
      if (role != 1) {
        debugPrint('⚠️ 보호자 계정이 아닙니다 (role: $role)');
        return null;
      }

      // 연결 상태 확인
      final isConnected = data['is_connected'] as bool? ?? false;
      if (!isConnected) {
        debugPrint('⚠️ 아직 시니어와 연결되지 않았습니다');
        return null;
      }

      // seniorId 가져오기
      final seniorId = data['seniorId'] as String?;
      if (seniorId == null || seniorId.isEmpty) {
        debugPrint('⚠️ seniorId가 비어있습니다 (is_connected=true이지만 seniorId 누락)');
        return null;
      }

      debugPrint('✅ 연결된 시니어 찾음: $seniorId');
      return seniorId;
    } catch (e) {
      debugPrint('❌ 연결된 시니어 조회 실패: $e');
      return null;
    }
  }

  /// 시니어가 연결된 보호자의 UID를 가져옵니다.
  ///
  /// [seniorUid] 시니어의 UID
  /// 반환: 보호자 UID 또는 null
  Future<String?> getConnectedGuardianUid(String seniorUid) async {
    if (seniorUid.isEmpty) {
      debugPrint('⚠️ ConnectionService: seniorUid가 비어있습니다.');
      return null;
    }

    try {
      final doc = await _firestore.collection('users').doc(seniorUid).get();

      if (!doc.exists) {
        debugPrint('⚠️ 시니어 문서를 찾을 수 없습니다: $seniorUid');
        return null;
      }

      final data = doc.data();
      if (data == null) return null;

      // 역할 확인
      final role = data['role'] as int?;
      if (role != 2) {
        debugPrint('⚠️ 시니어 계정이 아닙니다 (role: $role)');
        return null;
      }

      // 연결 상태 확인
      final isConnected = data['is_connected'] as bool? ?? false;
      if (!isConnected) {
        debugPrint('⚠️ 아직 보호자와 연결되지 않았습니다');
        return null;
      }

      // guardianId 가져오기
      final guardianId = data['guardianId'] as String?;
      if (guardianId == null || guardianId.isEmpty) {
        debugPrint(
          '⚠️ guardianId가 비어있습니다 (is_connected=true이지만 guardianId 누락)',
        );
        return null;
      }

      debugPrint('✅ 연결된 보호자 찾음: $guardianId');
      return guardianId;
    } catch (e) {
      debugPrint('❌ 연결된 보호자 조회 실패: $e');
      return null;
    }
  }

  /// 연결 상태를 실시간으로 모니터링합니다.
  ///
  /// [uid] 사용자 ID
  /// 반환: 연결 상태 Stream (true: 연결됨, false: 연결 안됨)
  Stream<bool> watchConnectionStatus(String uid) {
    if (uid.isEmpty) {
      debugPrint('⚠️ ConnectionService: uid가 비어있습니다.');
      return Stream.value(false);
    }

    return _firestore
        .collection('users')
        .doc(uid)
        .snapshots()
        .map((snapshot) {
          if (!snapshot.exists) {
            debugPrint('⚠️ 사용자 문서가 존재하지 않습니다: $uid');
            return false;
          }

          final data = snapshot.data();
          if (data == null) return false;

          final isConnected = data['is_connected'] as bool? ?? false;
          return isConnected;
        })
        .handleError((error) {
          debugPrint('❌ 연결 상태 모니터링 에러: $error');
          return false;
        });
  }

  /// 사용자의 전체 연결 정보를 가져옵니다.
  ///
  /// [uid] 사용자 ID
  /// 반환: ConnectionInfo 또는 null
  Future<ConnectionInfo?> getConnectionInfo(String uid) async {
    if (uid.isEmpty) return null;

    try {
      final doc = await _firestore.collection('users').doc(uid).get();

      if (!doc.exists) return null;

      final data = doc.data();
      if (data == null) return null;

      return ConnectionInfo(
        uid: uid,
        role: data['role'] as int? ?? 0,
        isConnected: data['is_connected'] as bool? ?? false,
        guardianId: data['guardianId'] as String?,
        seniorId: data['seniorId'] as String?,
        connectCode: data['connect_code'] as String?,
        name: data['name'] as String? ?? '알 수 없음',
      );
    } catch (e) {
      debugPrint('❌ 연결 정보 조회 실패: $e');
      return null;
    }
  }

  /// 보호자 화면에서 사용할 시니어 UID를 가져옵니다.
  ///
  /// 보호자가 로그인한 경우 연결된 시니어의 UID를 반환하고,
  /// 시니어가 로그인한 경우 자신의 UID를 반환합니다.
  ///
  /// [currentUserUid] 현재 로그인한 사용자의 UID
  /// 반환: 데이터를 조회할 시니어 UID
  Future<ConnectionResult> resolveTargetSeniorUid(String currentUserUid) async {
    debugPrint(
      '🔍 [ConnectionService] resolveTargetSeniorUid 시작: uid=$currentUserUid',
    );

    try {
      // 1. 현재 사용자 역할 확인
      debugPrint('📋 [ConnectionService] 사용자 역할 조회 중...');
      final role = await getUserRole(currentUserUid);

      if (role == null) {
        debugPrint('❌ [ConnectionService] 사용자 정보 없음');
        return ConnectionResult(success: false, message: '사용자 정보를 찾을 수 없습니다');
      }

      debugPrint('✅ [ConnectionService] 역할: $role (1=보호자, 2=시니어)');

      // 2. 보호자인 경우
      if (role == 1) {
        debugPrint('👮 [ConnectionService] 보호자 계정 → 연결된 시니어 찾기');
        final seniorUid = await getConnectedSeniorUid(currentUserUid);

        if (seniorUid == null) {
          debugPrint('⚠️ [ConnectionService] 연결된 시니어 없음');
          return ConnectionResult(
            success: false,
            message: '연결된 시니어가 없습니다\n먼저 시니어와 연결해주세요',
          );
        }

        debugPrint('✅ [ConnectionService] 연결된 시니어: $seniorUid');
        return ConnectionResult(
          success: true,
          targetUid: seniorUid,
          message: '연결된 시니어의 데이터를 조회합니다',
        );
      }

      // 3. 시니어인 경우
      if (role == 2) {
        debugPrint('👴 [ConnectionService] 시니어 계정 → 본인 데이터 조회');
        return ConnectionResult(
          success: true,
          targetUid: currentUserUid,
          message: '본인의 데이터를 조회합니다',
        );
      }

      // 4. 알 수 없는 역할
      debugPrint('❌ [ConnectionService] 알 수 없는 역할: $role');
      return ConnectionResult(success: false, message: '알 수 없는 사용자 역할입니다');
    } catch (e, stackTrace) {
      debugPrint('❌ [ConnectionService] resolveTargetSeniorUid 오류: $e');
      debugPrint('Stack: $stackTrace');
      return ConnectionResult(success: false, message: '오류가 발생했습니다: $e');
    }
  }
}

/// 연결 정보 모델
class ConnectionInfo {
  final String uid;
  final int role; // 1: 보호자, 2: 시니어
  final bool isConnected;
  final String? guardianId;
  final String? seniorId;
  final String? connectCode;
  final String name;

  ConnectionInfo({
    required this.uid,
    required this.role,
    required this.isConnected,
    this.guardianId,
    this.seniorId,
    this.connectCode,
    required this.name,
  });

  String get roleText => role == 1
      ? '보호자'
      : role == 2
      ? '시니어'
      : '알 수 없음';

  String get connectedPartnerId {
    if (role == 1) return seniorId ?? '';
    if (role == 2) return guardianId ?? '';
    return '';
  }
}

/// 연결 처리 결과
class ConnectionResult {
  final bool success;
  final String? targetUid;
  final String message;

  ConnectionResult({
    required this.success,
    this.targetUid,
    required this.message,
  });
}
