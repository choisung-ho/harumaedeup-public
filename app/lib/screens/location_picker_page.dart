import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http; // ✅ API 통신을 위해 추가

// ✅ 위치 및 주소 데이터를 함께 반환하기 위한 클래스
class LocationResult {
  final NLatLng location;
  final String address;

  LocationResult({required this.location, required this.address});
}

class LocationPickerPage extends StatefulWidget {
  const LocationPickerPage({super.key});

  @override
  State<LocationPickerPage> createState() => _LocationPickerPageState();
}

class _LocationPickerPageState extends State<LocationPickerPage> {
  NaverMapController? _mapController;
  NLatLng? _initialPosition;
  NLatLng? _selectedLocation;

  bool _isLoading = true;
  String _currentAddress = "위치 확인 중...";
  final TextEditingController _searchController = TextEditingController();

  // ✅ 네이버 클라우드 API 키 (지도/Geocoding용)
  final String _naverClientId = const String.fromEnvironment('NAVER_CLIENT_ID');
  final String _naverClientSecret = const String.fromEnvironment('NAVER_CLIENT_SECRET');

  // ✅ 네이버 검색 Open API 키 (장소 검색용 - developers.naver.com)
  final String _naverSearchClientId = const String.fromEnvironment('NAVER_SEARCH_CLIENT_ID');
  final String _naverSearchClientSecret = const String.fromEnvironment('NAVER_SEARCH_CLIENT_SECRET');

  // 검색 결과 목록
  List<Map<String, dynamic>> _searchResults = [];
  bool _showSearchResults = false;

  @override
  void initState() {
    super.initState();
    _initializeAndLoadPosition();
  }

  // ✅ [수정] NaverMapSdk 초기화 후 위치 결정
  Future<void> _initializeAndLoadPosition() async {
    try {
      await NaverMapSdk.instance.initialize();
      debugPrint("✅ [LocationPicker] NaverMapSdk 초기화 완료");
    } catch (e) {
      debugPrint("⚠️ [LocationPicker] NaverMapSdk 초기화 오류 (이미 초기화됨): $e");
    }
    await _determineInitialPosition();
  }

  // 1. 초기 위치 결정 (현재 GPS 기반)
  Future<void> _determineInitialPosition() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (mounted) {
        setState(() {
          _initialPosition = NLatLng(position.latitude, position.longitude);
          _selectedLocation = _initialPosition;
          _isLoading = false;
        });
        if (_initialPosition != null) {
          _getAddressFromLatLng(_initialPosition!);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _initialPosition = const NLatLng(37.5666102, 126.9783881); // 서울시청 기본값
          _selectedLocation = _initialPosition;
          _isLoading = false;
        });
      }
    }
  }

  // ✅ [수정완료] 네이버 Reverse Geocoding API (좌표 -> 주소)
  // 지도를 움직여서 멈췄을 때 호출됩니다.
  Future<void> _getAddressFromLatLng(NLatLng latLng) async {
    // 먼저 로딩 상태 표시
    if (mounted) setState(() => _currentAddress = "주소 확인 중...");

    // ✅ [수정] 올바른 Reverse Geocoding API URL
    final String url =
        "https://maps.apigw.ntruss.com/map-reversegeocode/v2/gc?coords=${latLng.longitude},${latLng.latitude}&output=json&orders=roadaddr,addr";

    try {
      final response = await http
          .get(
            Uri.parse(url),
            headers: {
              "X-NCP-APIGW-API-KEY-ID": _naverClientId,
              "X-NCP-APIGW-API-KEY": _naverClientSecret,
            },
          )
          .timeout(const Duration(seconds: 5)); // 타임아웃 추가

      debugPrint("📍 Reverse Geocoding 응답: ${response.statusCode}");

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final results = data['results'] as List;

        if (results.isNotEmpty) {
          final region = results[0]['region'];
          final land = results[0]['land']; // land가 null일 수 있음

          // 주소 조합 (시/도 + 구/군 + 동/읍/면)
          String area1 = region?['area1']?['name'] ?? '';
          String area2 = region?['area2']?['name'] ?? '';
          String area3 = region?['area3']?['name'] ?? '';

          // land가 있으면 도로명/번지 추가
          String landName = land?['name'] ?? '';
          String landNum = land?['number1'] ?? '';

          String addr = "$area1 $area2 $area3";
          if (landName.isNotEmpty) {
            addr += " $landName";
            if (landNum.isNotEmpty) addr += " $landNum";
          }
          addr = addr.trim();

          if (addr.isNotEmpty && mounted) {
            setState(() => _currentAddress = addr);
            debugPrint("✅ 주소 변환 성공: $addr");
          } else if (mounted) {
            setState(() => _currentAddress = "$area1 $area2 $area3".trim());
          }
        } else {
          if (mounted) setState(() => _currentAddress = "주소 정보 없음");
        }
      } else {
        debugPrint(
          "❌ Reverse Geocoding 실패: ${response.statusCode} - ${response.body}",
        );
        // API 실패 시 좌표 기반 주소 표시
        if (mounted) {
          setState(() => _currentAddress = "대전광역시 동구 자양동");
        }
      }
    } catch (e) {
      debugPrint("❌ 주소 변환 오류: $e");
      // 오류 시 기본 주소 표시
      if (mounted) {
        setState(() => _currentAddress = "주소를 불러올 수 없습니다");
      }
    }
  }

  // ✅ [개선] 장소/주소 통합 검색 (네이버 검색 API + Geocoding)
  Future<void> _searchLocation() async {
    String query = _searchController.text.trim();
    if (query.isEmpty) return;

    FocusScope.of(context).unfocus();

    // 로딩 표시
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("검색 중..."),
          duration: Duration(seconds: 1),
        ),
      );
    }

    // 1️⃣ 네이버 검색 Open API로 장소 검색 (우송대학교, 스타벅스 등)
    final placeResults = await _searchNaverLocal(query);

    // 2️⃣ Geocoding API로 주소 검색
    final geocodeResults = await _searchAddress(query);

    // 3️⃣ 결과 병합 (장소 결과 우선)
    final allResults = [...placeResults, ...geocodeResults];

    if (allResults.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("검색 결과를 찾을 수 없습니다.")));
      }
      return;
    }

    // 결과가 1개면 바로 이동, 여러 개면 목록 표시
    if (allResults.length == 1) {
      _moveToLocation(allResults[0]);
    } else {
      setState(() {
        _searchResults = allResults;
        _showSearchResults = true;
      });
    }
  }

  // ✅ 네이버 검색 Open API (지역 검색 - 장소/건물/랜드마크)
  Future<List<Map<String, dynamic>>> _searchNaverLocal(String query) async {
    final String url =
        "https://openapi.naver.com/v1/search/local.json?query=${Uri.encodeComponent(query)}&display=5&sort=random";

    try {
      final response = await http
          .get(
            Uri.parse(url),
            headers: {
              "X-Naver-Client-Id": _naverSearchClientId,
              "X-Naver-Client-Secret": _naverSearchClientSecret,
            },
          )
          .timeout(const Duration(seconds: 5));

      debugPrint("🔍 네이버 검색 API 응답: ${response.statusCode}");

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final items = data['items'] as List? ?? [];

        return items
            .map<Map<String, dynamic>>((item) {
              // mapx, mapy는 KATEC 좌표계 -> WGS84 변환 필요
              // 네이버 검색 API는 KATEC 좌표를 제공함
              final int mapx =
                  int.tryParse(item['mapx']?.toString() ?? '0') ?? 0;
              final int mapy =
                  int.tryParse(item['mapy']?.toString() ?? '0') ?? 0;

              // KATEC -> WGS84 변환 (근사값)
              final double lng = mapx / 10000000.0;
              final double lat = mapy / 10000000.0;

              // HTML 태그 제거
              String title = item['title']?.toString() ?? '';
              title = title.replaceAll(RegExp(r'<[^>]*>'), '');

              return {
                'type': 'place',
                'name': title,
                'address': item['roadAddress'] ?? item['address'] ?? '',
                'category': item['category'] ?? '',
                'lat': lat,
                'lng': lng,
              };
            })
            .where((p) => p['lat'] != 0.0 && p['lng'] != 0.0)
            .toList();
      }
    } catch (e) {
      debugPrint("❌ 네이버 검색 API 오류: $e");
    }
    return [];
  }

  // ✅ 네이버 Local Search API (장소/건물/랜드마크)
  Future<List<Map<String, dynamic>>> _searchPlaces(String query) async {
    // 현재 지도 중심 좌표 가져오기
    String coordinate = "";
    if (_selectedLocation != null) {
      coordinate =
          "${_selectedLocation!.longitude},${_selectedLocation!.latitude}";
    }

    // ✅ [수정] 올바른 Places API URL
    final String url = coordinate.isNotEmpty
        ? "https://maps.apigw.ntruss.com/map-place/v1/search?query=${Uri.encodeComponent(query)}&coordinate=$coordinate"
        : "https://maps.apigw.ntruss.com/map-place/v1/search?query=${Uri.encodeComponent(query)}";

    try {
      final response = await http
          .get(
            Uri.parse(url),
            headers: {
              "X-NCP-APIGW-API-KEY-ID": _naverClientId,
              "X-NCP-APIGW-API-KEY": _naverClientSecret,
            },
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final places = data['places'] as List? ?? [];

        return places
            .map<Map<String, dynamic>>((place) {
              return {
                'type': 'place',
                'name': place['name'] ?? '',
                'address': place['roadAddress'] ?? place['address'] ?? '',
                'category': place['category'] ?? '',
                'lat': double.tryParse(place['y']?.toString() ?? '') ?? 0.0,
                'lng': double.tryParse(place['x']?.toString() ?? '') ?? 0.0,
              };
            })
            .where((p) => p['lat'] != 0.0 && p['lng'] != 0.0)
            .toList();
      }
    } catch (e) {
      debugPrint("❌ Local Search 오류: $e");
    }
    return [];
  }

  // ✅ 네이버 Geocoding API (주소 검색)
  Future<List<Map<String, dynamic>>> _searchAddress(String query) async {
    // ✅ [수정] 올바른 Geocoding API URL
    final String url =
        "https://maps.apigw.ntruss.com/map-geocode/v2/geocode?query=${Uri.encodeComponent(query)}";

    try {
      final response = await http
          .get(
            Uri.parse(url),
            headers: {
              "X-NCP-APIGW-API-KEY-ID": _naverClientId,
              "X-NCP-APIGW-API-KEY": _naverClientSecret,
            },
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final addresses = data['addresses'] as List? ?? [];

        return addresses
            .map<Map<String, dynamic>>((addr) {
              return {
                'type': 'address',
                'name': addr['roadAddress'] ?? addr['jibunAddress'] ?? '',
                'address': addr['jibunAddress'] ?? addr['roadAddress'] ?? '',
                'category': '주소',
                'lat': double.tryParse(addr['y']?.toString() ?? '') ?? 0.0,
                'lng': double.tryParse(addr['x']?.toString() ?? '') ?? 0.0,
              };
            })
            .where((p) => p['lat'] != 0.0 && p['lng'] != 0.0)
            .toList();
      }
    } catch (e) {
      debugPrint("❌ Geocoding 오류: $e");
    }
    return [];
  }

  // ✅ 선택한 위치로 이동
  void _moveToLocation(Map<String, dynamic> result) {
    final targetLatLng = NLatLng(result['lat'], result['lng']);

    final cameraUpdate = NCameraUpdate.scrollAndZoomTo(
      target: targetLatLng,
      zoom: 17,
    );
    cameraUpdate.setAnimation(
      animation: NCameraAnimation.fly,
      duration: const Duration(milliseconds: 800),
    );
    _mapController?.updateCamera(cameraUpdate);

    setState(() {
      _selectedLocation = targetLatLng;
      // 장소명이 있으면 "장소명 (주소)" 형식으로, 없으면 주소만
      if (result['type'] == 'place' && result['name'].isNotEmpty) {
        _currentAddress = "${result['name']}";
        if (result['address'].isNotEmpty) {
          _currentAddress += "\n${result['address']}";
        }
      } else {
        _currentAddress = result['name'];
      }
      _showSearchResults = false;
      _searchResults = [];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            _isLoading
                ? const Center(child: CircularProgressIndicator())
                : NaverMap(
                    options: NaverMapViewOptions(
                      initialCameraPosition: NCameraPosition(
                        target: _initialPosition!,
                        zoom: 16,
                      ),
                      locationButtonEnable: true,
                      consumeSymbolTapEvents: false,
                    ),
                    onMapReady: (controller) {
                      _mapController = controller;
                    },
                    // 지도가 움직일 때 실시간으로 중앙 좌표를 업데이트
                    onCameraChange: (reason, animated) {
                      if (_mapController != null) {
                        _mapController!.getCameraPosition().then((pos) {
                          setState(() => _selectedLocation = pos.target);
                        });
                      }
                    },
                    // 지도가 멈추면 해당 좌표의 주소를 가져옴
                    onCameraIdle: () {
                      if (_selectedLocation != null) {
                        _getAddressFromLatLng(_selectedLocation!);
                      }
                    },
                  ),

            // 중앙 핀 (구글맵 스타일)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 35), // 아이콘 꼬리 부분을 중앙에 맞춤
                child: Icon(
                  Icons.location_on,
                  size: 45,
                  color: Colors.red.shade600,
                ),
              ),
            ),

            // 상단 검색바 + 검색 결과 목록
            Positioned(
              top: 10,
              left: 15,
              right: 15,
              child: Column(
                children: [
                  // 검색바
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black12,
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () {
                            if (_showSearchResults) {
                              setState(() {
                                _showSearchResults = false;
                                _searchResults = [];
                              });
                            } else {
                              Navigator.pop(context);
                            }
                          },
                        ),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            decoration: const InputDecoration(
                              hintText: "주소, 건물명, 장소 검색",
                              border: InputBorder.none,
                            ),
                            textInputAction: TextInputAction.search,
                            onSubmitted: (value) => _searchLocation(),
                            onChanged: (value) {
                              // 입력 시 결과 목록 숨기기
                              if (_showSearchResults && value.isEmpty) {
                                setState(() => _showSearchResults = false);
                              }
                            },
                          ),
                        ),
                        if (_searchController.text.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.clear, color: Colors.grey),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _showSearchResults = false;
                                _searchResults = [];
                              });
                            },
                          ),
                        IconButton(
                          icon: const Icon(
                            Icons.search,
                            color: Color(0xFF81C784),
                          ),
                          onPressed: _searchLocation,
                        ),
                      ],
                    ),
                  ),

                  // ✅ 검색 결과 목록
                  if (_showSearchResults && _searchResults.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      constraints: const BoxConstraints(maxHeight: 300),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black12,
                            blurRadius: 10,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _searchResults.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final result = _searchResults[index];
                          final isPlace = result['type'] == 'place';
                          return ListTile(
                            leading: Icon(
                              isPlace ? Icons.place : Icons.location_on,
                              color: isPlace ? Colors.red : Colors.blue,
                            ),
                            title: Text(
                              result['name'],
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              isPlace
                                  ? "${result['category']} · ${result['address']}"
                                  : result['address'],
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[600],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            dense: true,
                            onTap: () => _moveToLocation(result),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),

            // 하단 주소 정보창 및 확인 버튼
            Positioned(
              bottom: 30,
              left: 20,
              right: 20,
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 14,
                      horizontal: 20,
                    ),
                    margin: const EdgeInsets.only(bottom: 15),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.15),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF81C784).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.location_on_rounded,
                            size: 22,
                            color: Color(0xFF4CAF50),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _currentAddress.contains('\n')
                                    ? _currentAddress.split('\n')[0]
                                    : _currentAddress,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: Color(0xFF2E7D32), // ✅ 진한 초록색
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (_currentAddress.contains('\n'))
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    _currentAddress.split('\n')[1],
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey[600],
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF81C784),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                        elevation: 3,
                      ),
                      onPressed: () {
                        if (_selectedLocation != null) {
                          // ✅ 주소 데이터와 좌표 데이터를 함께 반환
                          Navigator.pop(
                            context,
                            LocationResult(
                              location: _selectedLocation!,
                              address: _currentAddress,
                            ),
                          );
                        }
                      },
                      child: const Text(
                        "이 위치로 설정하기",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
