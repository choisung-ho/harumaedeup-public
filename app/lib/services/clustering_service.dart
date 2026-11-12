import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import '../models/cluster_suggestion.dart';

/// 얼굴 클러스터링 관련 서비스
/// Firestore 읽기 및 Cloud Functions 호출을 담당합니다.
class ClusteringService {
  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  ClusteringService({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _functions = functions ?? FirebaseFunctions.instance;

  /// 사용자의 클러스터 제안 목록을 실시간으로 가져옵니다.
  /// [uid] 사용자 ID
  /// 반환: Stream<List<ClusterSuggestion>> - 실시간으로 업데이트되는 클러스터 목록
  Stream<List<ClusterSuggestion>> getClusterSuggestions(String uid) {
    if (uid.isEmpty) {
      debugPrint('⚠️ ClusteringService: uid가 비어있습니다.');
      return Stream.value([]);
    }

    debugPrint('🔍 [ClusteringService] 클러스터 조회 시작: uid=$uid');

    // ✅ [수정] 인덱스 없이도 작동하도록 쿼리 단순화
    // orderBy만 사용하고, status 필터링은 클라이언트에서 처리
    return _firestore
        .collection('users')
        .doc(uid)
        .collection('cluster_suggestions')
        .orderBy('created_at', descending: true)
        .snapshots()
        .map((snapshot) {
          debugPrint(
            '📊 [ClusteringService] ${snapshot.docs.length}개 문서 수신 (필터링 전)',
          );

          final clusters = snapshot.docs
              .map((doc) {
                try {
                  return ClusterSuggestion.fromFirestore(doc);
                } catch (e) {
                  debugPrint('❌ 클러스터 파싱 실패 (${doc.id}): $e');
                  return null;
                }
              })
              .whereType<ClusterSuggestion>()
              .where(
                (cluster) => cluster.isValid && cluster.status == 'UNLABELED',
              ) // ← 클라이언트 필터링
              .toList();

          debugPrint(
            '✅ [ClusteringService] UNLABELED 클러스터: ${clusters.length}개',
          );
          return clusters;
        })
        .handleError((error) {
          debugPrint('❌ ClusteringService Stream 에러: $error');
          return <ClusterSuggestion>[];
        });
  }

  /// 클러스터에 라벨(이름)을 등록합니다.
  /// [uid] 사용자 ID
  /// [groupId] 클러스터 그룹 ID
  /// [name] 등록할 이름 (예: "할머니", "엄마")
  /// [excludeFaceIds] 제외할 얼굴 ID 목록 (선택적)
  ///
  /// 반환: 성공 여부와 메시지를 포함한 결과
  Future<ClusterActionResult> registerFaceLabel({
    required String uid,
    required String groupId,
    required String name,
    List<String>? excludeFaceIds,
  }) async {
    try {
      debugPrint('🏷️ 라벨 등록 시작: uid=$uid, groupId=$groupId, name=$name');

      // 입력 검증
      if (uid.isEmpty || groupId.isEmpty || name.trim().isEmpty) {
        return ClusterActionResult(success: false, message: '필수 정보가 누락되었습니다.');
      }

      // Cloud Function 호출
      final callable = _functions.httpsCallable('register_face_label');
      final result = await callable.call(<String, dynamic>{
        'uid': uid,
        'group_id': groupId,
        'name': name.trim(),
        if (excludeFaceIds != null && excludeFaceIds.isNotEmpty)
          'exclude_face_ids': excludeFaceIds,
      });

      final data = result.data as Map<String, dynamic>? ?? {};
      final success = data['success'] as bool? ?? false;
      final message = data['message'] as String? ?? '알 수 없는 응답';

      debugPrint(success ? '✅ 라벨 등록 성공: $message' : '⚠️ 라벨 등록 실패: $message');

      return ClusterActionResult(success: success, message: message);
    } on FirebaseFunctionsException catch (e) {
      debugPrint('❌ Firebase Functions 에러: ${e.code} - ${e.message}');
      return ClusterActionResult(
        success: false,
        message: '서버 오류가 발생했습니다: ${e.message ?? e.code}',
      );
    } catch (e) {
      debugPrint('❌ 라벨 등록 예외: $e');
      return ClusterActionResult(success: false, message: '오류가 발생했습니다: $e');
    }
  }

  /// 클러스터 제안을 거부합니다.
  /// [uid] 사용자 ID
  /// [groupId] 클러스터 그룹 ID
  ///
  /// 반환: 성공 여부와 메시지를 포함한 결과
  Future<ClusterActionResult> rejectClusterSuggestion({
    required String uid,
    required String groupId,
  }) async {
    try {
      debugPrint('🚫 클러스터 거부 시작: uid=$uid, groupId=$groupId');

      // 입력 검증
      if (uid.isEmpty || groupId.isEmpty) {
        return ClusterActionResult(success: false, message: '필수 정보가 누락되었습니다.');
      }

      // Cloud Function 호출
      final callable = _functions.httpsCallable('reject_cluster_suggestion');
      final result = await callable.call(<String, dynamic>{
        'uid': uid,
        'group_id': groupId,
      });

      final data = result.data as Map<String, dynamic>? ?? {};
      final success = data['success'] as bool? ?? false;
      final message = data['message'] as String? ?? '알 수 없는 응답';

      debugPrint(
        success ? '✅ 클러스터 거부 성공: $message' : '⚠️ 클러스터 거부 실패: $message',
      );

      return ClusterActionResult(success: success, message: message);
    } on FirebaseFunctionsException catch (e) {
      debugPrint('❌ Firebase Functions 에러: ${e.code} - ${e.message}');
      return ClusterActionResult(
        success: false,
        message: '서버 오류가 발생했습니다: ${e.message ?? e.code}',
      );
    } catch (e) {
      debugPrint('❌ 클러스터 거부 예외: $e');
      return ClusterActionResult(success: false, message: '오류가 발생했습니다: $e');
    }
  }

  /// 특정 클러스터의 상세 정보를 가져옵니다.
  /// [uid] 사용자 ID
  /// [groupId] 클러스터 그룹 ID
  ///
  /// 반환: 클러스터 정보 또는 null
  Future<ClusterSuggestion?> getClusterDetail({
    required String uid,
    required String groupId,
  }) async {
    try {
      final doc = await _firestore
          .collection('users')
          .doc(uid)
          .collection('cluster_suggestions')
          .doc(groupId)
          .get();

      if (!doc.exists) {
        debugPrint('⚠️ 클러스터를 찾을 수 없습니다: $groupId');
        return null;
      }

      return ClusterSuggestion.fromFirestore(doc);
    } catch (e) {
      debugPrint('❌ 클러스터 조회 실패: $e');
      return null;
    }
  }
}

/// 클러스터 액션(라벨 등록/거부) 결과
class ClusterActionResult {
  final bool success;
  final String message;

  ClusterActionResult({required this.success, required this.message});
}
