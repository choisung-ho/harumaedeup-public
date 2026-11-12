import 'package:cloud_firestore/cloud_firestore.dart';

class PatientLog {
  final String id;
  final String content;
  final DateTime date;
  final List<String> imageUrls; // ✅ 사진 주소들을 담을 리스트 추가
  final String? videoUrl;       // ✅ 동영상 주소를 담을 칸 추가
  final DateTime createdAt;

  PatientLog({
    required this.id,
    required this.content,
    required this.date,
    required this.imageUrls, // ✅ 생성자에 추가
    this.videoUrl,           // ✅ 생성자에 추가
    required this.createdAt,
  });

  // 📤 데이터를 DB에 보낼 때 쓰는 함수
  Map<String, dynamic> toMap() {
    return {
      'content': content,
      'date': Timestamp.fromDate(date),
      'imageUrls': imageUrls, // ✅ 필드 추가
      'videoUrl': videoUrl,   // ✅ 필드 추가
      'createdAt': FieldValue.serverTimestamp(),
    };
  }

  // 📥 DB에서 데이터를 가져올 때 쓰는 함수
  factory PatientLog.fromDoc(DocumentSnapshot doc) {
    Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
    return PatientLog(
      id: doc.id,
      content: data['content'] ?? '',
      date: (data['date'] as Timestamp).toDate(),
      // ✅ DB에 저장된 리스트를 가져와서 다트 리스트로 변환
      imageUrls: List<String>.from(data['imageUrls'] ?? []),
      videoUrl: data['videoUrl'],
      createdAt: (data['createdAt'] as Timestamp).toDate(),
    );
  }
}
