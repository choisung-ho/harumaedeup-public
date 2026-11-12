import 'dart:convert';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:intl/intl.dart';

class ArchiveService {

  // [✅ 핵심] 1시간마다 실행될 함수: 기존 파일에 내용을 추가(Append)하고 DB 청소
  static Future<void> archiveHourly(String docId) async {
    print("⏳ [Hourly Archive] 1시간 단위 저장 시작: $docId");

    // 1. Firestore 데이터 위치 (읽어올 곳)
    final collectionRef = FirebaseFirestore.instance
        .collection('users')
        .doc(docId)
        .collection('location_logs');

    // 2. Storage 저장 위치 (저장할 곳) - ✅ [경로 통일] archives 폴더 추가
    final storageRef = FirebaseStorage.instance
        .ref()
        .child('user_logs')
        .child(docId)
        .child('archives'); // 👈 이렇게 폴더를 하나 더 만들어서 관리하면 깔끔합니다.

    try {
      // 3. DB에서 현재 쌓여있는 모든 로그 가져오기
      final snapshot = await collectionRef.get();

      if (snapshot.docs.isEmpty) {
        print("📂 [Archive] 저장할 새로운 데이터가 없습니다.");
        return;
      }

      print("📊 [Archive] 총 ${snapshot.docs.length}개의 새로운 기록을 발견했습니다.");

      // 4. 날짜별로 데이터 분류 (혹시 날짜가 섞여 있을까봐)
      Map<String, List<Map<String, dynamic>>> dailyLogs = {};
      List<String> docsToDelete = [];

      for (var doc in snapshot.docs) {
        Map<String, dynamic> data = doc.data();
        DateTime? timestamp;

        // Timestamp 타입 처리
        if (data['timestamp'] is Timestamp) {
          timestamp = (data['timestamp'] as Timestamp).toDate();
        } else if (data['timestamp'] is String) {
          timestamp = DateTime.tryParse(data['timestamp']);
        }

        if (timestamp != null) {
          String dateKey = DateFormat('yyyy-MM-dd').format(timestamp);

          if (!dailyLogs.containsKey(dateKey)) {
            dailyLogs[dateKey] = [];
          }

          dailyLogs[dateKey]!.add({
            'lat': data['lat'],
            'lng': data['lng'],
            'timestamp': timestamp.toIso8601String(),
          });

          docsToDelete.add(doc.id);
        }
      }

      // 5. 날짜별로 스토리지 파일 처리 (다운로드 -> 합치기 -> 업로드)
      for (String dateKey in dailyLogs.keys) {
        String fileName = "log_$dateKey.json"; // 파일명: log_2024-05-21.json (통일)
        final fileRef = storageRef.child(fileName);

        List<dynamic> existingData = [];
        List<Map<String, dynamic>> newData = dailyLogs[dateKey]!;

        // (1) 기존 파일이 있는지 확인하고 다운로드
        try {
          // 최대 10MB까지 메모리로 다운로드
          final Uint8List? data = await fileRef.getData(10 * 1024 * 1024);
          if (data != null) {
            String content = utf8.decode(data);
            existingData = jsonDecode(content);
            print("📥 [Download] 기존 데이터 ${existingData.length}개 로드됨.");
          }
        } catch (e) {
          print("✨ [New File] 기존 파일 없음, 새로 생성합니다.");
        }

        // (2) 기존 데이터 + 새 데이터 합치기
        existingData.addAll(newData);

        // (3) 다시 JSON으로 변환하여 업로드 (덮어쓰기)
        String finalJson = jsonEncode(existingData);
        await fileRef.putString(finalJson, format: PutStringFormat.raw, metadata: SettableMetadata(contentType: 'application/json'));

        print("📤 [Upload] $fileName 업데이트 완료 (총 ${existingData.length}개 데이터)");
      }

      // 6. DB 삭제 (스토리지 저장이 확실히 끝난 후 실행)
      int batchCount = 0;
      WriteBatch batch = FirebaseFirestore.instance.batch();

      for (String id in docsToDelete) {
        batch.delete(collectionRef.doc(id));
        batchCount++;

        // Firestore 배치 제한(500개) 준수
        if (batchCount >= 499) {
          await batch.commit();
          batch = FirebaseFirestore.instance.batch();
          batchCount = 0;
        }
      }

      if (batchCount > 0) {
        await batch.commit();
      }

      print("🗑 [Clean] DB에서 ${docsToDelete.length}개의 기록을 삭제하여 용량을 확보했습니다.");

    } catch (e) {
      print("❌ [Error] 아카이빙 중 오류 발생: $e");
    }
  }
}
