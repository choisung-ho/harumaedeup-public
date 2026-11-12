import 'package:cloud_firestore/cloud_firestore.dart';

/// 얼굴 클러스터 제안 모델
/// 백엔드에서 자동으로 생성된 얼굴 그룹 데이터를 표현합니다.
class ClusterSuggestion {
  /// Firestore 문서 ID (그룹 ID)
  final String groupId;

  /// 대표 썸네일 이미지 URL
  final String thumbnailUrl;

  /// 샘플 이미지 URL 목록 (최대 5개)
  final List<String> sampleImageUrls;

  /// 클러스터에 포함된 얼굴 멤버 정보
  final List<ClusterMember> members;

  /// 사진 개수
  final int photoCount;

  /// 현재 상태 (UNLABELED, LABELED 등)
  final String status;

  /// 생성 시각
  final DateTime? createdAt;

  ClusterSuggestion({
    required this.groupId,
    required this.thumbnailUrl,
    required this.sampleImageUrls,
    required this.members,
    required this.photoCount,
    required this.status,
    this.createdAt,
  });

  /// Firestore DocumentSnapshot에서 모델 생성
  /// null 안전성을 보장하며, 필드가 없거나 잘못된 경우 기본값을 사용합니다.
  factory ClusterSuggestion.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};

    print('📦 [ClusterSuggestion] 문서 ID: ${doc.id}');
    print('📦 [ClusterSuggestion] thumbnail_url: ${data['thumbnail_url']}');
    print(
      '📦 [ClusterSuggestion] sample_image_urls: ${data['sample_image_urls']}',
    );
    print('📦 [ClusterSuggestion] members: ${data['members']}');

    return ClusterSuggestion(
      groupId: doc.id,
      thumbnailUrl: data['thumbnail_url'] as String? ?? '',
      sampleImageUrls: _parseSampleImageUrls(data['sample_image_urls']),
      members: _parseMembers(data['members']),
      photoCount: data['photo_count'] as int? ?? 0,
      status: data['status'] as String? ?? 'UNLABELED',
      createdAt: _parseTimestamp(data['created_at']),
    );
  }

  /// sample_image_urls 필드를 안전하게 파싱
  static List<String> _parseSampleImageUrls(dynamic value) {
    if (value == null) return [];
    if (value is List) {
      return value.whereType<String>().where((url) => url.isNotEmpty).toList();
    }
    return [];
  }

  /// members 필드를 안전하게 파싱
  static List<ClusterMember> _parseMembers(dynamic value) {
    if (value == null) return [];
    if (value is List) {
      return value
          .where((item) => item is Map)
          .map((item) => ClusterMember.fromMap(item as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  /// Timestamp를 DateTime으로 변환
  static DateTime? _parseTimestamp(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }

  /// 유효한 클러스터인지 확인 (최소한의 데이터가 있는지)
  bool get isValid => thumbnailUrl.isNotEmpty && photoCount > 0;
}

/// 클러스터 멤버 (개별 얼굴 정보)
class ClusterMember {
  /// 얼굴 문서 ID
  final String id;

  /// 얼굴 썸네일 이미지 URL
  final String faceUrl;

  /// 원본 이미지 URL (선택적)
  final String? originalUrl;

  ClusterMember({required this.id, required this.faceUrl, this.originalUrl});

  /// Map에서 모델 생성
  factory ClusterMember.fromMap(Map<String, dynamic> map) {
    return ClusterMember(
      id: map['id'] as String? ?? '',
      faceUrl:
          map['face_url'] as String? ??
          map['url'] as String? ??
          map['image_url'] as String? ??
          '',
      originalUrl: map['original_url'] as String?,
    );
  }

  /// 유효한 멤버인지 확인
  bool get isValid => id.isNotEmpty && faceUrl.isNotEmpty;
}
