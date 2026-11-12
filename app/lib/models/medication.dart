import 'package:cloud_firestore/cloud_firestore.dart';

class Medication {
  final String id;
  final String name;
  final String time; // "08:30" 형식
  final List<int> days; // 1(월) ~ 7(일)

  Medication({required this.id, required this.name, required this.time, required this.days});

  factory Medication.fromFirestore(DocumentSnapshot doc) {
    Map data = doc.data() as Map<String, dynamic>;
    return Medication(
      id: doc.id,
      name: data['name'] ?? '약',
      time: data['time'] ?? '09:00',
      days: List<int>.from(data['days'] ?? []),
    );
  }
}
