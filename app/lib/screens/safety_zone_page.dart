import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:kpostal/kpostal.dart'; // 주소 검색
import 'package:geocoding/geocoding.dart'; // 좌표 변환
import '../theme_state.dart';

// =============================================================================
// 1. 목록 화면 (메인) - 기존과 동일
// =============================================================================
class SafetyZonePage extends StatefulWidget {
  final String patientId;
  const SafetyZonePage({super.key, required this.patientId});

  @override
  State<SafetyZonePage> createState() => _SafetyZonePageState();
}

class _SafetyZonePageState extends State<SafetyZonePage> {
  // 안심 구역 삭제
  Future<void> _deleteZone(String zoneId) async {
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.patientId)
          .collection('safe_zones')
          .doc(zoneId)
          .delete();

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("삭제되었습니다.")));
      }
    } catch (e) {
      debugPrint("삭제 실패: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("안심 구역 관리")),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  SafetyZoneEditor(patientId: widget.patientId),
            ),
          );
        },
        label: const Text("구역 추가"),
        icon: const Icon(Icons.add_location_alt_rounded),
        backgroundColor: Colors.blue,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(widget.patientId)
            .collection('safe_zones')
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());

          final docs = snapshot.data!.docs;

          if (docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.security, size: 60, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    "등록된 안심 구역이 없습니다.\n아래 버튼을 눌러 추가해주세요.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            separatorBuilder: (c, i) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final data = docs[index].data() as Map<String, dynamic>;
              final id = docs[index].id;
              final name = data['name'] ?? '이름 없음';
              final radius = data['radius'] ?? 500;

              return Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 2,
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.blue,
                    child: Icon(Icons.location_on, color: Colors.white),
                  ),
                  title: Text(
                    name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text("반경 ${radius.toInt()}m"),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => _deleteZone(id),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// =============================================================================
// 2. 지도 에디터 화면 (수정됨: 장소 이름 입력창 제거 -> 주소 검색창으로 변경)
// =============================================================================
class SafetyZoneEditor extends StatefulWidget {
  final String patientId;
  const SafetyZoneEditor({super.key, required this.patientId});

  @override
  State<SafetyZoneEditor> createState() => _SafetyZoneEditorState();
}

class _SafetyZoneEditorState extends State<SafetyZoneEditor> {
  NaverMapController? _mapController;

  // 주소 표시용 컨트롤러 (입력용 X, 표시용 O)
  final TextEditingController _addressController = TextEditingController();

  NLatLng _currentCenter = const NLatLng(37.5665, 126.9780);
  double _radius = 30.0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _moveToCurrentLocation();
  }

  Future<void> _moveToCurrentLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition();
      setState(() {
        _currentCenter = NLatLng(position.latitude, position.longitude);
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  // 주소 검색 기능
  Future<void> _searchAddress() async {
    try {
      Kpostal? result = await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => KpostalView()),
      );

      if (result != null && result.address.isNotEmpty) {
        List<Location> locations = await locationFromAddress(result.address);
        if (locations.isNotEmpty) {
          final loc = locations.first;
          final newTarget = NLatLng(loc.latitude, loc.longitude);

          _moveCamera(newTarget);

          // ✅ 검색된 주소를 상단 검색창에 표시
          setState(() {
            _addressController.text = result.address;
          });

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("'${result.address}'로 이동했습니다.")),
          );
        }
      }
    } catch (e) {
      debugPrint("주소 검색 오류: $e");
    }
  }

  void _moveCamera(NLatLng target) {
    setState(() => _currentCenter = target);
    if (_mapController != null) {
      _mapController!.updateCamera(
        NCameraUpdate.scrollAndZoomTo(target: target, zoom: 18),
      );
      _updateCircleOverlay();
    }
  }

  void _updateCircleOverlay() {
    if (_mapController == null) return;
    _mapController!.clearOverlays();

    final circle = NCircleOverlay(
      id: 'editor_circle',
      center: _currentCenter,
      radius: _radius,
      color: Colors.green.withOpacity(0.2),
      outlineColor: Colors.green,
      outlineWidth: 2,
    );

    final marker = NMarker(
      id: 'center_marker',
      position: _currentCenter,
      caption: const NOverlayCaption(text: "여기!"),
    );

    _mapController!.addOverlayAll({circle, marker});
  }

  // 저장 버튼 누르면 -> 팝업창에서 이름 입력 (학교, 집 등)
  void _showNameInputDialog() {
    final TextEditingController nameController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text("장소 이름 입력"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "예: 집, 학교, 복지관 등",
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: "이 장소를 무엇이라 부를까요?",
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("취소", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                if (nameController.text.trim().isEmpty) return;
                Navigator.pop(context);
                _saveToFirebase(nameController.text.trim());
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              child: const Text("저장", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  // 실제 Firebase 저장
  Future<void> _saveToFirebase(String zoneName) async {
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.patientId)
          .collection('safe_zones')
          .add({
            'name': zoneName,
            'address': _addressController.text, // (선택) 검색된 주소도 같이 저장
            'latitude': _currentCenter.latitude,
            'longitude': _currentCenter.longitude,
            'radius': _radius,
            'createdAt': FieldValue.serverTimestamp(),
          });

      if (mounted) {
        Navigator.pop(context); // 목록으로 복귀
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("'$zoneName' 구역이 추가되었습니다."),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("저장 실패: $e")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("위치 지정")),
      body: Column(
        children: [
          // ✅ [수정됨] "장소 이름" 입력창 제거 -> "주소 검색창"으로 변경
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: GestureDetector(
              onTap: _searchAddress, // 누르면 주소 검색
              child: AbsorbPointer(
                // 텍스트 입력 방지 (터치 이벤트만 받음)
                child: TextField(
                  controller: _addressController,
                  readOnly: true, // 키보드 안 올라오게 설정
                  decoration: InputDecoration(
                    hintText: "지번, 도로명, 건물명으로 검색", // 힌트 텍스트 변경
                    prefixIcon: const Icon(Icons.search, color: Colors.blue),
                    filled: true,
                    fillColor: Colors.grey[100],
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 0,
                      horizontal: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 지도
          Expanded(
            child: Stack(
              children: [
                NaverMap(
                  options: NaverMapViewOptions(
                    initialCameraPosition: NCameraPosition(
                      target: _currentCenter,
                      zoom: 15,
                    ),
                    mapType: NMapType.basic,
                  ),
                  onMapReady: (controller) {
                    _mapController = controller;
                    _updateCircleOverlay();
                  },
                  onCameraChange: (reason, animated) async {
                    if (_mapController != null) {
                      final pos = await _mapController!.getCameraPosition();
                      _currentCenter = pos.target;
                    }
                  },
                  onCameraIdle: () {
                    setState(() {});
                    _updateCircleOverlay();
                  },
                ),
                const Center(
                  child: Icon(
                    Icons.add_location_alt,
                    color: Colors.red,
                    size: 40,
                  ),
                ),
                // ✅ 내 위치 보기 버튼 (좌하단, 네이버 로고 위)
                Positioned(
                  left: 16,
                  bottom: 60,
                  child: FloatingActionButton.small(
                    heroTag: 'my_location_btn',
                    backgroundColor: Colors.white,
                    onPressed: () async {
                      try {
                        Position position =
                            await Geolocator.getCurrentPosition();
                        final newTarget = NLatLng(
                          position.latitude,
                          position.longitude,
                        );
                        _moveCamera(newTarget);
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('현재 위치를 가져올 수 없습니다.')),
                          );
                        }
                      }
                    },
                    child: const Icon(Icons.my_location, color: Colors.blue),
                  ),
                ),
              ],
            ),
          ),

          // 하단 컨트롤 패널
          Container(
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)],
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "반경 설정",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      "${_radius.toInt()} m",
                      style: const TextStyle(
                        color: Colors.blue,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _radius,
                  min: 10,
                  max: 50,
                  divisions: 8,
                  activeColor: Colors.blue,
                  onChanged: (v) {
                    setState(() => _radius = v);
                    _updateCircleOverlay();
                  },
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _showNameInputDialog, // 저장 시 팝업 호출
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      "이 위치로 설정 저장",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
